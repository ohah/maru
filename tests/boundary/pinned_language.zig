// 이 테스트는 **언어가 박힌 표시 문자열이 늘지 않게** 한다(docs/i18n.md §7.2 4차).
//
// **무엇을 증명하나.** 제품 코드에서 언어를 박거나 정하는 자리가 원장에 적힌 것뿐이다. 두 축을 본다 —
// `tIn` 은 한 문자열을 얼리고, `setLang`·`applyPreference`·`setOsLocale` 은 **모든 키**를 얼린다.
//
// **왜 이 게이트가 필요한가 — 컴파일러가 절반만 막는다.**
// 컨테이너 수준 `const` 에 런타임 조회를 넣으면 컴파일러가 막는다:
//
//     const frozen = i18n.t(.set_nav_hint);
//     // error: unable to evaluate comptime expression        (언어 상태가 원자값이다)
//     // note:  initializer of container-level variable must be comptime-known
//
// **그런데 언어를 인자로 박으면 통과한다.** `tIn` 은 comptime 에 값이 정해지므로 comptime 자리에 들어갈
// 수 있고, 그 순간 그 문자열은 **한 언어로 얼어붙는다.** 실측:
//
//     const pinned = i18n.tIn(.ko, .set_nav_hint);
//     …
//     PINNED=← 섹션 · → 설정 · ↑↓ 이동 · ⏎ 선택
//     LIVE  =← section · → setting · ↑↓ move · ⏎ select   ← 같은 프레임, 다른 언어
//
// **기존 게이트 어느 것도 이것을 못 본다.** 리터럴 게이트는 "우변이 리터럴인가" 를 보는데 우변은 호출이고,
// 고아 키 게이트는 "참조가 있는가" 를 보는데 참조는 있다. 즉 이 형태는 **모든 검사를 통과하면서 한 언어로
// 굳는다** — 사용자가 `ui.language` 를 바꿔도 그 화면만 안 따라온다.
//
// **왜 0 이 아니라 원장인가.** 모바일 표면 전체가 아직 런타임 언어 전환을 안 받는다. 설정 행 목록이
// `inline for` 로 만드는 comptime 테이블이라 런타임 조회를 못 쓰고(`mobile_config.zig` 의 `mobileDocLabel`
// doc 주석), 그리기 경로는 그 화면과 **같은 말을 써야** 해서 함께 `ko` 로 고정돼 있다(`mobile_bridge.zig` 의
// `session_title` doc 주석). 그것은 번역 문제가 아니라 **모바일이 OS 로케일을 아직 안 받는다는 구조**다.
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//
// **이것은 토큰 스캐너이고, 스캐너는 철자를 본다.** 같은 일을 하는 표기는 무한히 많으므로 "전부 잡는다" 는
// 목표가 될 수 없다. 여섯 라운드에 걸쳐 적대적 검증이 새 철자를 매번 찾아냈다(`Lang.ko` →
// `@field(Lang,"ko")` → `@field(Lang, name)` → `@call(.auto, tIn, …)` → 여러 줄 문자열 `\\ko` →
// `@import("i18n.zig").setLang(.ko)`).
// 그것을 하나씩 막는 것은 이기는 싸움이 아니다.
//
// 그래서 이 게이트가 서 있는 자리는 이렇다 — **실수는 잡고, 의도적 우회는 리뷰가 잡는다.** 계약 §7.3 이
// 리터럴 게이트에 대해 이미 받아들인 것과 같은 선이다. 지금 열려 있는 것을 **알면서** 적어 둔다. 목록은
// **두 축 모두에 해당한다**:
//
//   · `@call(.auto, i18n.tIn, .{ .ko, k })` / `@call(.auto, i18n.setLang, .{.ko})` — 이름 뒤가 `(` 가
//     아니라 세지 않는다.
//   · 별칭(`const f = i18n.tIn;` · `const s = i18n.setLang;`)과 따옴표 식별자(`i18n.@"tIn"`).
//   · `@field(Lang, name)` 에서 `name` 이 식별자일 때 — `const name = "ko";` 를 위에 두면 한 언어가 된다.
//     이름이 리터럴이 아닌 것을 "언어를 도는 코드" 로 읽는 것이 유일한 면제이고, 그 면제는 정직하게 말해
//     **표기에 대한 신뢰**다. **이 항목만은 `tIn` 축에만 해당한다** — 프로세스 축에는 `@field` 면제가
//     없어서 닫혀 있다. 앞 판은 목록 전체가 두 축에 해당한다고 적었는데 이 하나가 거짓이었다.
//   · `@field(i18n, "setLang")(.ko)` / `@field(i18n, "tIn")(.ko, k)` — 이름이 **문자열 리터럴 토큰 안**에
//     있어 두 축 다 못 본다. 별칭·따옴표 식별자와는 다른 메커니즘이라 따로 적는다(실측으로 컴파일되고
//     언어가 박힌다).
//   · `roots` 가 `src` 뿐이라 `tests/**` 의 **최상위 `fn`**(= `test` 블록이 아닌 헬퍼)은 두 축 다 안 본다.
//     원장이 `settingsRowKeys` 를 "테스트만 부르는 헬퍼인데 최상위 `fn` 이라" 는 이유로 적어 둔 것과
//     대칭이 안 맞는다 — 같은 헬퍼를 `tests/` 로 옮기면 원장에서 사라진다.
//   · 원장에 적힌 파일 **안에서** 수가 그대로면 자리가 바뀌어도 모른다. 그 파일 안에 래퍼를 만들어 여러
//     호출을 하나로 접으면 수가 준다.
//   · `roots` 가 `src` 뿐이다. `tools/` 는 안 훑는다(오늘 그쪽에 i18n 사용은 0 이다).
//   · 표 자신(`src/i18n.zig`)은 **파일째** 면제다. 그 안에 `pub fn koLabel(k)` 을 두면 호출부는 영원히
//     0 이다. 그 위반은 오늘 0 이고, 막으려면 표의 공개 표면 전체를 명부로 고정해야 하는데 그것은
//     **가정에 대한 방어**라 걷어냈다(아래 `@hasDecl` 주석 참고). 리뷰가 본다.
//   · `ui.language` 의 **기본값**을 `.ko` 로 바꾸면 프로세스째 한국어가 되는데 호출 수는 안 움직인다.
//     그 축은 `loader.zig` 의 파싱 테스트가 기본값 `.auto` 를 고정해 지킨다 — 이 게이트가 아니다.
//   · 심링크된 **디렉터리**는 walker 가 안 들어간다. 그래서 `src/` 안의 `.zig` 아닌 심링크를 만나면
//     **실패시킨다** — 조용히 안 보는 것보다 시끄럽게 막는 쪽이 낫다.
//
// **막을 수 있는데 스캐너로 막은 것은 없다.** 표를 직접 읽는 길(`i18n.ko.<키>`)은 이 게이트가 영영 못 보므로
// `en`/`ko` 를 **비공개로 닫았다** — 가시성이 막을 수 있는 것을 스캐너로 막지 않는다.
//
// **그 밖의 성질.**
//   · **언어 인자가 어디서 왔는지 못 본다.** `tIn(.ko, k)`(박은 것)와 `tIn(resolved, k)`(해상도가 끝난 값을
//     흘린 것)는 토큰으로 구별할 수 없다 — 후자는 계약을 **지키는** 형태인데도 세어진다. 그래서 세는 쪽을
//     기본값으로 두고, 판정은 사람이 해서 **원장에 사유와 함께 적는다**. 원장은 부채 목록이자 "사람이 봤다"
//     는 기록이다. 놓치는 쪽으로 기울이면 그 기록조차 안 남는다.
//
//     이 원칙을 한 번 어겼다. 프로세스 축에서 흔한 이름의 오탐이 **걱정돼** 한정자(`i18n.<이름>(`)를
//     요구했는데, 그 오탐은 저장소에 실재하지 않았고(충돌하는 정의는 표 자신뿐) 대신
//     `@import("i18n.zig").setLang(.ko)` 을 놓쳤다 — 그 인라인 import 표기는 `schema.zig` 가 이미 쓰는
//     관용이다. **없는 오탐을 막느라 있는 검출을 버렸다.** 지금은 다시 넓게 세고, `fn <이름>(` 정의만 뺀다.
//   · **원장은 "박힌 문자열" 이 아니라 "호출 자리" 를 센다.** `mobileDocLabel` 은 `tIn` 호출 **하나**로
//     스키마의 모든 doc 라벨을 박는다 — 라벨을 백 개 붙여도 원장은 안 움직인다.
//   · 번역 문자열을 dupe 해 캐시하는 형태는 이 게이트의 대상이 아니다 — 그 축은 계약 §5.2 가 맡는다.
const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("posix_walk.zig").posixWalk;

/// 프로세스의 언어를 정하는 호출을 **이름별로** 센 결과.
///
/// 한 숫자로 합치지 않는 이유는, 합치면 같은 파일 안에서 **정당한 자리를 지우고 그 자리에 못을 박는**
/// 치환이 수를 안 바꿔 초록으로 지나가기 때문이다 — `applyPreference(cfg)` 를 `setLang(.ko)` 로 바꾸면
/// 런타임 언어 전환이 죽는데 합계는 그대로다(실측했다).
const Process = struct {
    set_lang: usize = 0,
    apply_preference: usize = 0,
    set_os_locale: usize = 0,

    /// 이 축이 보는 이름들. **한 곳에서만 적는다** — 세는 쪽·비교하는 쪽·더하는 쪽이 각자 목록을 알면
    /// 넷째 이름을 넣을 때 한 곳을 빠뜨린다.
    const names = std.meta.fieldNames(Process);
    /// 소스에 나타나는 철자(필드 이름과 순서가 같아야 한다).
    const spellings = [_][]const u8{ "setLang", "applyPreference", "setOsLocale" };

    comptime {
        if (names.len != spellings.len) @compileError("Process 필드와 철자 목록이 어긋난다");
        // **길이만 보면 순서가 어긋나도 지나간다.** 그러면 진단이 이름을 잘못 붙여 출력하고, 읽는 사람이
        // 원인을 반대로 짚는다. 철자(camelCase)를 필드 이름(snake_case)으로 바꿔 짝을 확인한다.
        for (names, spellings) |field, spelling| {
            if (!std.mem.eql(u8, field, snakeCase(spelling)))
                @compileError("Process 필드 `" ++ field ++ "` 와 철자 `" ++ spelling ++ "` 가 짝이 아니다");
        }
    }

    fn total(self: Process) usize {
        var sum: usize = 0;
        inline for (names) |f| sum += @field(self, f);
        return sum;
    }
    fn eql(self: Process, other: Process) bool {
        inline for (names) |f| {
            if (@field(self, f) != @field(other, f)) return false;
        }
        return true;
    }
    /// **어느 이름이라도 줄었는가.** 총계만 보면 "하나가 사라지고 다른 것이 둘 늘었다" 를 "늘었다" 로
    /// 읽고 "명부를 올려라" 라고 안내한다 — 사라진 쪽이 정당한 자리였으면 회귀를 정상으로 기록시킨다.
    fn anyDecreased(self: Process, expected: Process) bool {
        inline for (names) |f| {
            if (@field(self, f) < @field(expected, f)) return true;
        }
        return false;
    }
};

/// camelCase 를 snake_case 로. comptime 전용이다.
fn snakeCase(comptime camel: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (camel) |c| {
        if (c >= 'A' and c <= 'Z') {
            out = out ++ [_]u8{ '_', c + ('a' - 'A') };
        } else {
            out = out ++ [_]u8{c};
        }
    }
    return out;
}

/// 원장 한 줄.
const Entry = struct {
    path: []const u8,
    /// 한 문자열을 얼리는 자리(`tIn`)의 수.
    count: usize = 0,
    /// 프로세스의 언어를 정하는 자리. 이름별로 적는다.
    process: Process = .{},
};

const inventory = [_]Entry{
    // 모바일 그리기 경로. 이 화면은 런타임 언어 전환을 안 받으므로 `ko` 로 고정돼 있다
    // (`session_title` 의 doc 주석). 모바일이 OS 로케일을 받는 슬라이스가 이 수를 0 으로 만든다.
    // 원격 세션 목록(S10d-2)이 일곱을 더했다 — 목록의 세 상태(받는 중·없다·줄들)와 축이 꺼진
    // 네 이유. **같은 화면의 다른 줄들과 한 언어여야** 해서 같은 고정을 쓴다(모바일이 OS 로케일을
    // 아직 안 받는다는 위 구조 그대로다).
    //
    // 축이 꺼진 이유에 **"채널을 못 열었다"** 가 붙어 하나 더 늘었다. 여는 것은 host 라(소켓이
    // 그쪽에 있다) 실패도 host 만 아는데 알리는 통로가 없어, 목록이 이유도 모른 채 영영 "받는 중"
    // 이던 것을 고치면서 생긴 자리다 — 같은 `switch` 의 다른 팔들과 한 언어여야 한다.
    //
    // **원장은 늘 실측으로 적는다.** 여기서 한 번 38 로 적었다가 CI 가 37 이라고 알려 줬다 —
    // 눈으로 센 수를 적으면 그 차이만큼 게이트가 헐거워진다.
    // 41: 원격 축이 꺼진 이유를 갈라 적으면서 셋이 늘었다(계약 §4a — 127·다른 코드·폴백).
    // 42: 앱 바에 **끊는 자리**가 생겼다. 그 글자도 다른 앱 바 글자와 같은 자리에서 나온다 —
    //     모바일 UI 는 아직 언어 해상도를 안 거치고 `.ko` 를 박는다(위 주석의 그 이유).
    // 43: 끊긴 상태를 "붙는 중" 과 갈라 말한다 — 상태만으로 갈리는 자리라 문구가 하나 늘었다.
    // 44: 연결이 없으면 목록이 축의 사유 대신 연결을 말한다 — 그 자리의 폴백 문구다.
    // 53: 접근성 서술자(M9)가 셋을 더했다 — 앱 바 버튼들의 **읽을 이름**이다. 화면에 글자가 없는
    // 자리(뒤로가기 아이콘)까지 이름을 붙여야 스크린 리더가 읽으므로, 서술자를 다는 만큼 이 수는
    // 는다. **줄이 아니라 표면 전체가 걸린 문제다** — 모바일이 OS 로케일을 받는 슬라이스가 이
    // 원장을 통째로 0 으로 만든다.
    .{ .path = "src/platform/mobile/mobile_bridge.zig", .count = 57 },
    // 모바일 설정 행 목록이 comptime 테이블이라 런타임 조회를 못 쓴다(`mobileDocLabel` 의 doc 주석).
    // 9: `sectionOf` 가 namespace 마다 화면 헤더를 답하는데, 그 목록도 같은 comptime 테이블에서
    // 쓰인다 — `system_theme`(M13 시스템 다크/라이트)이 늘면서 한 줄이 늘었다. **줄이 아니라
    // 표면 전체가 걸린 문제다**: 모바일이 OS 로케일을 받는 슬라이스가 이 원장을 통째로 0 으로 만든다.
    .{ .path = "src/platform/mobile/mobile_config.zig", .count = 9 },
    // 골든 캡처용 실행 파일. 한국어 화면을 찍는 것이 목적이라 프로세스째 `ko` 로 박는다 —
    // 사용자 화면이 아니므로 `ui.language` 를 따를 이유가 없다.
    .{ .path = "src/platform/macos/chrome_lab_smoke.zig", .process = .{ .set_lang = 1 } },
    // 둘이다. ① 설정 화면이 `ui.language` 를 바꿨을 때 적용한다 — **정당한 자리**이고 이 축이 지키려는
    // 바로 그 경로다. ② `settingsRowKeys` — 테스트만 부르는 헬퍼인데 최상위 `fn` 이라 마스크에 안 걸린다
    // (두 언어의 행 집합이 같은지 보려고 언어를 바꾼다 — 계약 §5.2 를 **지키는** 쪽).
    .{ .path = "src/platform/macos/app_session/settings.zig", .process = .{ .apply_preference = 1, .set_lang = 1 } },
    // 설정을 다시 읽을 때 언어 선택을 적용한다 — **정당한 자리**다.
    .{ .path = "src/platform/macos/app_session.zig", .process = .{ .apply_preference = 1 } },
    // host 가 준 OS 로케일을 표에 전달한다 — `auto` 판정의 입력이고, **정당한 자리**다(계약 §5.1).
    .{ .path = "src/platform/macos/app_host_abi.zig", .process = .{ .set_os_locale = 1 } },
};

comptime {
    // 같은 경로를 두 번 적으면 **뒤엣것이 이기고 둘 다 소비 표시**돼 미소비 검사도 못 잡는다.
    for (inventory, 0..) |a, i| {
        for (inventory[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.path, b.path))
                @compileError("원장에 같은 경로가 두 번 적혀 있다: " ++ a.path);
        }
    }
}

const roots = [_][]const u8{"src"};

/// 표 자신. 이 파일만 면제한다.
const table_path = "src/i18n.zig";

/// 표 모듈. **가시성 하나만 컴파일러에게 묻는다**(`build.zig` 가 붙여 준다).
///
/// 그래서 이 파일은 `zig test tests/boundary/pinned_language.zig` 로 단독 실행되지 않는다 —
/// `zig build check-boundaries` 로 돌리거나, 급하면 모듈을 손으로 붙인다:
///
///     zig test --dep i18n_table \
///         -Mtest=tests/boundary/pinned_language.zig -Mi18n_table=src/i18n.zig
const table = @import("i18n_table");

comptime {
    // **표를 직접 읽는 길을 가시성으로 닫은 것이 되돌려지지 않게 한다.** `i18n.ko.<키>` 는 `tIn` 이라는
    // 글자가 없어 아래 두 축이 영영 못 본다(실측으로 컴파일되고 언어가 박힌다). 그래서 `en`/`ko` 를
    // 비공개로 바꿨고, 밖에 소비처가 0 인 `Table` 도 함께 닫았다. `pub` 을 다시 붙이면 여기서 걸린다.
    //
    // **표의 공개 표면 전체를 명부로 고정하는 판도 만들어 봤다가 걷어냈다.** 그것은 "표 안에 새 진입점을
    // 만들면" 이라는 **가정**에 대한 방어였고(위반 0), 손으로 짠 스캐너로 만들다 네 라운드를 잃었으며,
    // `@typeInfo` 로 옮긴 뒤에도 깊이 상한·`is_test` 갈림 같은 곁가지를 계속 낳았다. 실제로 이 브랜치가
    // 바꾼 것은 **이 셋의 가시성**이고, 그것만 못 박는다. 표에 새 진입점을 만드는 것은 리뷰가 본다 —
    // 계약 §7.3 이 리터럴 게이트에 대해 이미 받아들인 선과 같다.
    const closed = [_][]const u8{ "en", "ko", "Table" };
    for (closed) |name| {
        if (@hasDecl(table, name))
            @compileError("`" ++ name ++ "` 가 다시 공개됐다 — 표 값을 밖에서 직접 읽는 길이 열린다" ++
                " (`en`/`ko` 는 `i18n.<이름>.<키>` 로 두 축을 우회하고, `Table` 은 그 타입을 밖에 내준다)");
    }
}

/// `tIn` 호출을 센다. 찾은 자리의 줄 번호를 `lines` 에 담는다.
///
/// **세는 쪽이 기본값이다.** `tIn` 은 언어를 인자로 받는 순간 그 자리를 `ui.language` 에서 떼어 놓는다 —
/// 어떻게 적었든 그렇다. 그래서 "박은 형태를 알아보고 센다" 가 아니라 **"전부 세고 예외만 뺀다"** 로 짠다.
/// 반대로 짜면(첫 인자가 `.ko` 같은 enum 리터럴일 때만 세면) `tIn(Lang.ko, k)` 한 글자로 빠져나간다 —
/// 실제로 그 판을 먼저 썼다가 적대적 검증에 잡혔다.
///
/// 세 가지를 뺀다 — 코드 순서대로다.
///   ① `test` 블록(깊이 무관) ② `fn <이름>(` 정의(호출이 아니다) ③ 모든 언어를 **도는** 호출
///   · **`test` 블록(깊이 무관)** — 두 언어를 나란히 확인하는 것은 정상이고 오히려 권장하는 형태다.
///     중첩 `test` 까지 빼는 이유는 `remote_term_backend.zig` 가 `struct { test "…" {…} }` 로 쓰기
///     때문이다. 오늘 그 안에 `tIn` 은 없어 실제로 갈리는 자리는 0 개다 — 지금 나는 오탐을 고친 것이
///     아니라 **권장하는 형태를 쓸 때 나지 않게** 미리 막은 것이다.
///   · **모든 언어를 도는 호출** — 조건은 정확히 **첫 인자의 첫 토큰이 `@field` 이고 그 이름이 문자열
///     리터럴이 아닐 때**다. `settings.zig` 의 검색 필터가 화면 언어 의존을 없애려고 언어를 도는데
///     (계약 §5.2) 그것을 부채로 세면 이 게이트가 **고친 코드를 벌준다**.
fn countPinned(allocator: std.mem.Allocator, tree: *const std.zig.Ast, mask: []const bool, lines: *std.ArrayList(usize)) !usize {
    var total: usize = 0;
    for (tree.tokens.items(.tag), 0..) |_, i| {
        if (mask[i]) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(i)), "tIn")) continue;
        if (i + 2 >= tree.tokens.len) continue;
        // 이름 **바로 뒤가 `(`** 일 때만 호출이다(필드 이름·주석 안의 낱말이 아니라).
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(i + 1)), "(")) continue;
        // 정의는 호출이 아니다. 앞 판은 이 줄이 프로세스 축에만 있었고, 커밋 메시지는 "무관한 타입의
        // 동명 **정의** → 초록" 을 **두 축 모두에** 적었다 — 한쪽만 돌려 보고 전체로 적은 것이다.
        if (i >= 1 and std.mem.eql(u8, tree.tokenSlice(@intCast(i - 1)), "fn")) continue;
        if (std.mem.eql(u8, tree.tokenSlice(@intCast(i + 2)), "@field") and !fieldNameIsLiteral(tree, i + 2))
            continue;
        total += 1;
        try lines.append(allocator, tree.tokenLocation(0, @intCast(i)).line + 1);
    }
    return total;
}

/// 프로세스의 언어를 정하는 호출을 이름별로 센다. 이름별 줄 번호를 `lines` 에 담는다.
///
/// `tIn` 이 한 문자열을 얼린다면 이쪽은 **모든 키**를 얼린다 — 더 센 형태다. 처음에는 `setLang` 만 셌는데,
/// 그것은 **한 이름만 본 것**이었다. 표가 언어를 정하는 길은 셋이고 셋 다 같은 일을 한다:
///
///   · `setLang(<언어>)`         — 직접 박는다
///   · `applyPreference(<선택>)` — 안에서 `setLang(resolve(…))` 을 부른다. `resolve(.ko, …)` 는 무조건
///                                 `.ko` 이므로 `applyPreference(.ko)` 는 `setLang(.ko)` 와 같다
///   · `setOsLocale(<태그>)`     — `auto` 와 짝지으면 그 태그가 언어를 정한다
///
/// 앞 판은 `setLang` 만 셌고, **진단문이 "정당한 자리는 `applyPreference` 가 한다" 고 이름까지 적어
/// 가리켰다** — 그 문장을 읽고 그대로 따라간 사람이 정확히 구멍에 도착한다. 그래서 지금은 **정당한 자리도
/// 센다.** 이 축의 원장은 부채 목록이 아니라 **언어를 정하는 자리의 명부**다.
///
/// **한정자는 요구하지 않는다.** 흔한 이름이라 다른 타입의 동명 메서드가 오탐이 될 수 있지만, 그 오탐은
/// 저장소에 실재하지 않고(충돌하는 정의는 표 자신뿐) 한정자를 요구했다가 `@import("i18n.zig").setLang(.ko)`
/// 을 놓쳤다 — `schema.zig` 가 이미 쓰는 관용이다. 오탐은 원장에 사유를 적으면 되지만 누락은 조용하다.
/// 정의(`fn <이름>(`)만 뺀다.
fn countProcess(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    mask: []const bool,
    lines: *[Process.names.len]std.ArrayList(usize),
) !Process {
    var out: Process = .{};
    for (tree.tokens.items(.tag), 0..) |_, i| {
        if (mask[i]) continue;
        if (i + 1 >= tree.tokens.len) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(i + 1)), "(")) continue;
        // 정의는 호출이 아니다.
        if (i >= 1 and std.mem.eql(u8, tree.tokenSlice(@intCast(i - 1)), "fn")) continue;

        const name = tree.tokenSlice(@intCast(i));
        inline for (Process.names, Process.spellings, 0..) |field, spelling, slot| {
            if (std.mem.eql(u8, name, spelling)) {
                @field(out, field) += 1;
                try lines[slot].append(allocator, tree.tokenLocation(0, @intCast(i)).line + 1);
            }
        }
    }
    return out;
}

/// `@field(<ns>, <이름>)` 의 **이름 쪽이 문자열 리터럴인가**. 리터럴이면 그 호출은 한 언어를 고른 것이다.
///
/// 토큰만 본다 — 괄호 깊이를 세어 중첩 호출의 콤마를 집지 않는다. 여러 줄 문자열(`\\ko`)도 리터럴로 친다:
/// 따옴표만 보다가 그 철자로 면제가 다시 열렸고, 그것은 철자 문제가 아니라 **면제 로직 자신의 버그**였다.
fn fieldNameIsLiteral(tree: *const std.zig.Ast, field_token: usize) bool {
    var depth: usize = 0;
    var i = field_token + 1;
    while (i < tree.tokens.len) : (i += 1) {
        const part = tree.tokenSlice(@intCast(i));
        if (std.mem.eql(u8, part, "(")) {
            depth += 1;
        } else if (std.mem.eql(u8, part, ")")) {
            if (depth <= 1) return false;
            depth -= 1;
        } else if (depth == 1 and std.mem.eql(u8, part, ",")) {
            if (i + 1 >= tree.tokens.len) return false;
            const name = tree.tokenSlice(@intCast(i + 1));
            return std.mem.startsWith(u8, name, "\"") or std.mem.startsWith(u8, name, "\\\\");
        }
    }
    return false;
}

fn markConsumed(consumed: *[inventory.len]bool, path: []const u8) void {
    for (inventory, 0..) |e, idx| {
        if (std.mem.eql(u8, e.path, path)) consumed[idx] = true;
    }
}

/// `test` 블록(깊이 무관)에 속한 토큰 표시. 판정 규칙은 `source_digest.zig` 가 소유하므로 그것을 쓴다 —
/// 같은 규칙을 두 벌 두면 그 둘이 갈린다.
fn testMask(allocator: std.mem.Allocator, tree: *const std.zig.Ast) ![]bool {
    return @import("source_digest.zig").anyDepthTestTokenMask(allocator, tree);
}

test "언어를 박거나 정하는 자리가 원장과 같다 (i18n 계약 §7.2)" {
    const allocator = std.testing.allocator;
    var failed = false;
    var scanned: usize = 0;
    var consumed = [_]bool{false} ** inventory.len;

    // 찾은 자리의 줄 번호. 진단이 "이 파일에 N 개" 로 끝나면 6만 줄짜리 파일에서 사람이 손으로 찾는다.
    var pinned_lines: std.ArrayList(usize) = .empty;
    defer pinned_lines.deinit(allocator);
    var process_lines: [Process.names.len]std.ArrayList(usize) = @splat(.empty);
    defer for (&process_lines) |*l| l.deinit(allocator);

    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(std.testing.io);
        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();

        while (try walker.next(std.testing.io)) |entry| {
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, entry.path });

            // 심링크된 **디렉터리**에는 walker 가 안 들어간다. 조용히 안 보느니 시끄럽게 막는다.
            if (entry.kind == .sym_link and !std.mem.endsWith(u8, entry.basename, ".zig")) {
                failed = true;
                std.debug.print(
                    "{s}: `.zig` 가 아닌 심링크다 — walker 가 디렉터리 심링크에 안 들어가므로 그 안은\n" ++
                        "  **통째로 안 보인다**. 실제 디렉터리로 두거나, 그 안을 훑도록 이 게이트를 고쳐라.\n",
                    .{path},
                );
                continue;
            }
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            // 표 자신은 두 축을 **정의**한다 — 정의를 위반으로 세면 이 게이트가 늘 빨갛다.
            // **파일 이름이 아니라 경로로** 뺀다. 이름으로 빼면 아무 디렉터리에나 `i18n.zig` 를 두고
            // 그 안에서 마음껏 박을 수 있다(실측으로 통과했다).
            if (std.mem.eql(u8, path, table_path)) continue;

            // **읽기 실패에도 진단을 붙인다.** `try` 로 두면 파일 하나가 테스트를 끝내고, 그 뒤 파일은
            // **아무것도 검사되지 않은 채** 실패가 stdlib 버그처럼 보인다.
            const source = dir.readFileAllocOptions(
                std.testing.io,
                entry.path,
                allocator,
                .limited(8 * 1024 * 1024),
                .of(u8),
                0,
            ) catch |err| {
                failed = true;
                std.debug.print(
                    "{s}: 읽지 못했다({s}) — 이 파일은 검사되지 않았다.\n" ++
                        "  흔한 원인: 8 MiB 상한 초과(`StreamTooLong`), 깨진 심링크(`FileNotFound`),\n" ++
                        "  디렉터리를 가리키는 `.zig` 심링크(`IsDir`).\n",
                    .{ path, @errorName(err) },
                );
                markConsumed(&consumed, path);
                continue;
            };
            defer allocator.free(source);

            scanned += 1;
            pinned_lines.clearRetainingCapacity();
            for (&process_lines) |*l| l.clearRetainingCapacity();

            // **파싱 실패를 삼키지 않는다.** 삼키면 그 파일은 위반 0 으로 조용히 사라지고, 원장에 적힌
            // 파일이어도 "줄었다" 조차 안 뜬다 — 눈이 먼 상태를 통과로 읽는 것이다.
            // **파일마다 한 번만 파싱한다.** 두 세는 함수가 각자 파싱하던 판은 같은 트리·같은 마스크를
            // 두 번 만들었고, 그것만으로 이 게이트가 14.1 초 중 **7.2 초**를 썼다(실측).
            var tree = std.zig.Ast.parse(allocator, source, .zig) catch |err| {
                failed = true;
                std.debug.print("{s}: 파싱하지 못했다({s}) — 이 파일은 검사되지 않았다.\n", .{ path, @errorName(err) });
                markConsumed(&consumed, path);
                continue;
            };
            defer tree.deinit(allocator);
            if (tree.errors.len != 0) {
                failed = true;
                std.debug.print("{s}: 파싱 오류가 있다 — 이 파일은 검사되지 않았다.\n", .{path});
                markConsumed(&consumed, path);
                continue;
            }
            const mask = testMask(allocator, &tree) catch |err| {
                failed = true;
                std.debug.print("{s}: test 마스크를 못 만들었다({s}) — 이 파일은 검사되지 않았다.\n", .{ path, @errorName(err) });
                markConsumed(&consumed, path);
                continue;
            };
            defer allocator.free(mask);

            const found = try countPinned(allocator, &tree, mask, &pinned_lines);
            const process = try countProcess(allocator, &tree, mask, &process_lines);

            var expected: Entry = .{ .path = path };
            for (inventory, 0..) |e, idx| {
                if (!std.mem.eql(u8, e.path, path)) continue;
                expected = e;
                consumed[idx] = true;
            }

            if (!process.eql(expected.process)) {
                failed = true;
                std.debug.print("{s}: 프로세스의 언어를 정하는 자리가 명부와 다르다.\n", .{path});
                inline for (Process.names, Process.spellings, 0..) |field, spelling, slot| {
                    std.debug.print("        {s} {d} (명부 {d}) 자리 {any}\n", .{
                        spelling,
                        @field(process, field),
                        @field(expected.process, field),
                        process_lines[slot].items,
                    });
                }
                std.debug.print(
                    "  이 셋은 한 문자열이 아니라 **모든 키**를 얼린다. 명부는 부채 목록이 아니라\n" ++
                        "  **언어를 정하는 자리를 사람이 판정한 기록**이다 — 정당한 자리도 적혀 있다.\n",
                    .{},
                );
                // **어느 이름이라도 줄었으면 그것을 먼저 말한다.** 총계로만 가지를 고르면 "하나가 사라지고
                // 다른 것이 둘 늘었다" 를 "늘었다" 로 읽고 명부를 올리라고 안내한다 — 사라진 쪽이 정당한
                // 자리였으면 **회귀를 정상으로 기록시킨다**.
                if (process.anyDecreased(expected.process)) {
                    std.debug.print(
                        "  **줄어든 이름이 있다** — 명부를 내리기 전에 무엇이 사라졌는지 먼저 보라. 이 축에는\n" ++
                            "  정당한 자리가 들어 있고(설정 적용·host 로케일 전달), 그것이 사라졌다면 런타임 언어\n" ++
                            "  전환이 죽은 것이다. 그때 할 일은 명부를 내리는 것이 아니라 **되돌리는 것**이다.\n",
                        .{},
                    );
                } else {
                    std.debug.print(
                        "  **늘었다** — 그 자리가 정말 언어를 정해야 하는지 보고, 맞으면 사유를 적고 명부를 올려라.\n",
                        .{},
                    );
                }
                std.debug.print("  단일 출처: docs/i18n.md §7.2.\n", .{});
            }

            if (found == expected.count) continue;

            failed = true;
            if (found > expected.count) {
                std.debug.print(
                    "{s}: 언어를 인자로 받는 자리 {d} 개 (원장 {d}) — **늘었다**. 자리 {any}\n" ++
                        "  `tIn` 은 언어를 인자로 받는 순간 그 자리를 `ui.language` 에서 떼어 놓는다.\n" ++
                        "  **이 게이트는 그 인자가 어디서 왔는지 못 본다** — `.ko` 처럼 박은 것인지, 해상도가\n" ++
                        "  끝난 언어를 흘린 것인지 토큰으로는 구별할 수 없다. 판정은 사람이 한다:\n" ++
                        "    · 런타임 조회(`i18n.t`)를 쓸 수 있으면 그것을 써라 — 그러면 이 수가 준다.\n" ++
                        "    · 언어를 넘겨야 하는 자리면 **그 사실을 주석에 적고** 원장을 올려라.\n" ++
                        "  단일 출처: docs/i18n.md §7.2.\n",
                    .{ path, found, expected.count, pinned_lines.items },
                );
            } else {
                std.debug.print(
                    "{s}: 언어를 인자로 받는 자리 {d} 개 (원장 {d}) — **줄었다**. 자리 {any}\n" ++
                        "  원장을 이 값으로 낮춰라.\n",
                    .{ path, found, expected.count, pinned_lines.items },
                );
            }
        }
    }

    // 훑은 파일이 0 이면 스캐너가 눈이 먼 것이다 — 그 상태도 "위반 없음" 으로 통과한다.
    // **미소비 진단보다 먼저 본다.** 순서를 뒤집으면 `src` 를 못 열었을 때 "파일이 사라졌다" 가 먼저
    // 찍혀서 읽는 사람이 원인을 반대로 짚는다. 이 경로에도 진단을 붙인다 — 다른 실패는 전부 사람이 읽을
    // 문장을 내는데 여기만 벌거벗은 오류를 내면, 하필 **가장 진단이 필요한 실패**가 가장 안 읽힌다.
    if (scanned == 0) {
        std.debug.print(
            "훑은 `.zig` 파일이 0 개다 — 스캐너가 눈이 멀었다(`{s}` 를 못 열었거나 비었다).\n" ++
                "  이 게이트는 cwd 가 저장소 루트라야 돈다(`build.zig` 가 `setCwd` 로 그렇게 준다).\n",
            .{roots[0]},
        );
    }
    try std.testing.expect(scanned > 0);

    for (inventory, consumed) |e, hit| {
        if (hit) continue;
        failed = true;
        std.debug.print("원장에 적힌 {s} 를 못 찾았다 — 파일이 사라졌거나 이름이 바뀌었다. 항목을 지워라.\n", .{e.path});
    }

    try std.testing.expect(!failed);
}

// 스캐너가 **정말로 구분하는지** 스스로 확인한다. 위 테스트는 위반이 없을 때 통과하는데, 판정이 늘
// 거짓이어도 똑같이 통과하기 때문이다.
test "스캐너는 박은 호출만 세고, 언어를 도는 것과 테스트 안의 것은 안 센다" {
    const a = std.testing.allocator;
    var lines: std.ArrayList(usize) = .empty;
    defer lines.deinit(a);
    const count = struct {
        fn f(al: std.mem.Allocator, ls: *std.ArrayList(usize), src: [:0]const u8) !usize {
            ls.clearRetainingCapacity();
            var tree = try std.zig.Ast.parse(al, src, .zig);
            defer tree.deinit(al);
            if (tree.errors.len != 0) return error.SourceHasParseErrors;
            const mask = try testMask(al, &tree);
            defer al.free(mask);
            return countPinned(al, &tree, mask, ls);
        }
    }.f;

    // 제품 코드에서 언어를 박은 호출 둘.
    try std.testing.expectEqual(@as(usize, 2), try count(a, &lines,
        \\pub fn a() []const u8 {
        \\    return i18n.tIn(.ko, .k1);
        \\}
        \\pub fn b() []const u8 {
        \\    return i18n.tIn(.en, .k2);
        \\}
    ));

    // **enum 리터럴이 아닌 표기도 센다.** 셋 다 컴파일되고 셋 다 언어가 박힌다 — 앞선 판이 "첫 인자가
    // `.` 일 때만" 세는 바람에 셋 다 통과시켰다(적대적 검증이 실측으로 잡았다).
    try std.testing.expectEqual(@as(usize, 3), try count(a, &lines,
        \\pub fn a() []const u8 {
        \\    return i18n.tIn(Lang.ko, .k1);
        \\}
        \\const pinned_lang: Lang = .ko;
        \\pub fn b() []const u8 {
        \\    return i18n.tIn(pinned_lang, .k1);
        \\}
        \\pub fn c(x: bool) []const u8 {
        \\    return i18n.tIn(if (x) .ko else .en, .k1);
        \\}
    ));

    // **`@field` 로 적어도 이름이 리터럴이면 센다** — 반사로 적었을 뿐 정확히 한 언어를 고른다.
    // 여러 줄 문자열도 리터럴이다(따옴표만 보다가 그 철자로 면제가 다시 열렸다).
    try std.testing.expectEqual(@as(usize, 3), try count(a, &lines,
        \\pub const a = i18n.tIn(@field(Lang, "ko"), .k1);
        \\pub const b = i18n.tIn(@field(maru.i18n.Lang, "en"), .k1);
        \\pub const c = i18n.tIn(@field(Lang,
        \\    \\ko
        \\), .k1);
    ));

    // **언어를 도는 코드는 안 센다** — 언어를 박는 것의 반대다(계약 §5.2 를 지키는 형태).
    try std.testing.expectEqual(@as(usize, 0), try count(a, &lines,
        \\pub fn matches(dk: Key, q: []const u8) bool {
        \\    inline for (@typeInfo(Lang).@"enum".fields) |lf| {
        \\        const s = i18n.tIn(@field(Lang, lf.name), dk);
        \\        if (indexOf(s, q) != null) return true;
        \\    }
        \\    return false;
        \\}
    ));

    // 중첩 `test` 안의 것도 안 센다 — `remote_term_backend.zig` 가 실제로 이 형태를 쓴다.
    try std.testing.expectEqual(@as(usize, 0), try count(a, &lines,
        \\pub const testing_api = struct {
        \\    test "두 언어를 나란히 본다" {
        \\        _ = i18n.tIn(.ko, .k1);
        \\    }
        \\};
    ));

    // 호출이 아닌 `tIn`(주석·다른 식별자·문자열 안)은 안 센다.
    try std.testing.expectEqual(@as(usize, 0), try count(a, &lines,
        \\// tIn 은 언어를 박는다
        \\pub const tIn_note = 1;
        \\pub const sample = "i18n.tIn(.ko, .k1)";
    ));

    // 줄 번호를 준다 — 6만 줄짜리 파일에서 "이 파일에 N 개" 는 진단이 아니다.
    _ = try count(a, &lines,
        \\pub fn a() []const u8 {
        \\    return i18n.tIn(.ko, .k1);
        \\}
    );
    try std.testing.expectEqualSlices(usize, &.{2}, lines.items);

    // 파싱 실패는 **오류로 나온다** — 0 으로 조용히 사라지지 않는다.
    try std.testing.expectError(error.SourceHasParseErrors, count(a, &lines, "pub fn broken( {"));
}

test "스캐너는 프로세스의 언어를 정하는 자리를 이름별로 센다" {
    const a = std.testing.allocator;
    var lines: [Process.names.len]std.ArrayList(usize) = @splat(.empty);
    defer for (&lines) |*l| l.deinit(a);
    const count = struct {
        fn f(al: std.mem.Allocator, ls: *[Process.names.len]std.ArrayList(usize), src: [:0]const u8) !Process {
            for (ls) |*l| l.clearRetainingCapacity();
            var tree = try std.zig.Ast.parse(al, src, .zig);
            defer tree.deinit(al);
            if (tree.errors.len != 0) return error.SourceHasParseErrors;
            const mask = try testMask(al, &tree);
            defer al.free(mask);
            return countProcess(al, &tree, mask, ls);
        }
    }.f;

    // 셋 다 언어를 정한다 — 이름별로 따로 센다. 앞 판은 `setLang` 만 셌고, 진단문이 `applyPreference` 를
    // "정당한 자리" 로 가리켜 그리로 안내했다(적대적 검증이 잡았다).
    try std.testing.expectEqual(Process{ .set_lang = 1, .apply_preference = 1, .set_os_locale = 1 }, try count(a, &lines,
        \\pub fn a() void {
        \\    i18n.setLang(.ko);
        \\    maru.i18n.applyPreference(.ko);
        \\    maru.i18n.setOsLocale("ko-KR");
        \\}
    ));

    // **한정자를 요구하지 않는다.** 요구했다가 이 표기를 놓쳤다 — `schema.zig` 가 이미 쓰는 관용이다.
    try std.testing.expectEqual(Process{ .set_lang = 2 }, try count(a, &lines,
        \\pub fn a() void {
        \\    @import("i18n.zig").setLang(.ko);
        \\}
        \\pub fn b() void {
        \\    const m = @import("i18n.zig");
        \\    m.setLang(.ko);
        \\}
    ));

    // **정의는 호출이 아니다.**
    try std.testing.expectEqual(Process{}, try count(a, &lines,
        \\pub fn setLang(l: Lang) void { _ = l; }
        \\pub fn applyPreference(p: Preference) void { _ = p; }
    ));

    // 테스트가 언어를 바꿔 보는 것은 정상이다 — 안 센다.
    try std.testing.expectEqual(Process{}, try count(a, &lines,
        \\test "두 언어를 본다" {
        \\    const before = i18n.lang();
        \\    defer i18n.setLang(before);
        \\    i18n.setLang(.ko);
        \\}
    ));

    // 호출이 아닌 이름은 안 센다.
    try std.testing.expectEqual(Process{}, try count(a, &lines,
        \\// i18n.setLang 은 프로세스째 박는다
        \\pub const setLang_note = 1;
    ));

    // 이름별로 줄 번호를 준다 — 자리 목록을 다시 합쳐 놓으면 어느 줄이 무엇인지 모른다.
    _ = try count(a, &lines,
        \\pub fn a() void {
        \\    i18n.setLang(.ko);
        \\    i18n.setOsLocale("ko");
        \\}
    );
    try std.testing.expectEqualSlices(usize, &.{2}, lines[0].items);
    try std.testing.expectEqualSlices(usize, &.{}, lines[1].items);
    try std.testing.expectEqualSlices(usize, &.{3}, lines[2].items);
}

test "줄어든 이름을 총계가 가리지 않는다" {
    // 하나가 사라지고 다른 것이 둘 늘면 총계는 **늘었다**. 총계로만 가지를 고르면 "명부를 올려라" 라고
    // 안내하고, 사라진 쪽이 정당한 자리였으면 회귀를 정상으로 기록시킨다.
    const expected: Process = .{ .apply_preference = 1, .set_lang = 1 };
    const now: Process = .{ .set_lang = 3 };
    try std.testing.expect(now.total() > expected.total());
    try std.testing.expect(now.anyDecreased(expected));
    try std.testing.expect(!now.eql(expected));

    // 아무것도 안 줄었으면 순수한 증가다.
    const grown: Process = .{ .apply_preference = 1, .set_lang = 2 };
    try std.testing.expect(!grown.anyDecreased(expected));
}
