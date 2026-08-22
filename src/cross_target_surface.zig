//! **다른 OS 타깃에서도 컴파일되는지**를 중립 표면 **전체**에 대해 강제로 확인한다.
//!
//! `zig build check-targets` 는 `src/maru.zig` 를 세 타깃(aarch64-macos·x86_64-linux·x86_64-windows)
//! 으로 **컴파일만** 한다. 형태는 맞지만, 그것만으로는 **테스트가 참조하는 것까지만** 분석된다 —
//! Zig 는 함수 본문을 게으르게 분석하고 `std.testing.refAllDecls` 는 **비재귀**라 최상위 이름에서
//! 멈춘다.
//!
//! **그 구멍이 하필 ADE 표면 크기였다**(W8 착수 실측, 계약 §2m.2). 고의로 깨지는 호출
//! (`std.c.fork()` — Windows 에서 `std.c.fork` 는 `void` 라 호출이 반드시 컴파일 오류다)을 심어
//! 쓸어 본 결과:
//!
//! ```text
//! 덮임      chrome/draw.Rect.inset          (테스트가 실제로 부른다)
//! 덮임      path_shape.relativeUnderRoot
//! 안 덮임   chrome/components/archive_detail/view.view   ← 에이전트 도크 상세
//! 안 덮임   chrome/components/session_dock/view.view     ← 세션 도크
//! 안 덮임   chrome/components/scm_dock/view.view         ← 소스 컨트롤 도크
//! ```
//!
//! 셋 다 **실제로는 Windows 에서 컴파일된다** — 코드는 멀쩡한데 그것을 지키는 게이트가 없었다.
//! W8 이 바로 그 표면들을 건드리므로 슬라이스보다 게이트가 먼저다.
//!
//! **이름을 손으로 나열하지 않는다.** 컴포넌트가 늘 때마다 목록을 고쳐야 하면 반드시 빠뜨린다 —
//! 그리고 빠뜨린 것이 정확히 "새로 추가돼서 아직 아무도 안 밟은 코드" 다. 그래서 네임스페이스를
//! **재귀로 훑는다.**
//!
//! ## 이 게이트가 **못** 보는 것 (실측)
//!
//! "중립 표면 전체" 라고 쓰면 과장이다. 같은 대조군(`std.c.fork()`)으로 공격해 두 구멍을 확인했다:
//!
//! | 구멍 | 덮이나 | 왜 | 지금 노출 |
//! |---|---|---|---|
//! | **제네릭 함수 본문** | **안 덮임** | 인스턴스화 없이는 Zig 가 본문을 분석할 수 없다 | 중립 표면에 16 개(chrome 3·session 9·config 4) |
//! | **비공개 + 아무도 안 부르는 함수** | **안 덮임** | `std.meta.declarations` 는 공개 선언만 준다 | 죽은 코드라 무해하지만 썩는다 |
//!
//! 제네릭 쪽은 **타입 생성자**(`IntentTable(comptime Intent: type)` 처럼 타입을 내는 것)면 소비자가
//! 인스턴스화하는 순간 분석되므로 실질 노출이 더 작다. 남는 위험은 `anytype` 을 받는 평범한 함수다 —
//! 그런 것을 새로 만들 때는 **호출하는 테스트를 같이 두는 것**이 이 게이트의 대체재다.
//!
//! ## 왜 `maru.zig` 가 아니라 `check-targets` 전용인가
//!
//! 처음에는 `maru.zig` 에 등록했는데, 그러면 호스트 `zig build test` 에서 `session_dock`·
//! `archive_detail`·`ui.button` 의 **44 개가 한 번 더 돌았다** — 그것들은 이미 `test-chrome-ui` 에서
//! 돌고 있어 순수한 중복이었다(적대적 검증이 잡았다: 2983 → 3028). 이 walker 가 필요한 것은
//! **크로스 타깃 컴파일**뿐이므로 `build.zig` 의 `check-targets` 안에서 자기 루트로 선다.

const std = @import("std");

/// 재귀 깊이 상한. **실측한 실제 최대 깊이는 5** 다(상한을 낮춰 가며 잰 것: 4 면 24 건, 5 면 0 건이
/// 걸린다). 12 는 그보다 7 겹 여유다 — 처음에 6 으로 뒀다가 여유가 1 뿐이라는 것을 적대적 검증이
/// 잡았다(한 겹만 더 중첩되면 조용히 잘린다).
///
/// **상한에 닿으면 조용히 넘어가지 않고 컴파일을 세운다.** 아무것도 안 하고 `return` 하면 그 아래가
/// 통째로 검사에서 빠지는데, 그 사실이 아무 데도 안 남는다 — "검사했다" 와 "검사를 건너뛰었다" 가
/// 똑같이 초록으로 보이는 부류다. 상한이 있는 이유(자기 자신을 품는 타입에서 comptime 이 안 끝나는
/// 것)는 그대로지만, 그때도 **말은 하고** 멈춘다.
const max_depth = 12;

/// `T` 아래의 모든 선언을 **주소 참조**해 함수 본문까지 의미 분석되게 만든다.
///
/// **주소 참조가 본문 분석을 강제한다** — 실측으로 확인했다(대조군: `_ = &fn;` 만 해도
/// `std.c.fork()` 를 잡는다). `std.testing.refAllDecls` 가 못 잡은 이유는 그것이 **한 겹만**
/// 보기 때문이지 주소 참조가 약해서가 아니다.
///
/// 타입 선언은 한 겹 더 들어간다. 그 외(상수·변수)는 값을 한 번 읽는 것으로 충분하다.
pub fn refAllRecursive(comptime T: type, comptime depth: usize) usize {
    // 중립 표면 전체를 comptime 에 도는 일이라 기본 분기 예산(1000)을 넘는다. 실측 선언 수의
    // 수십 배로 잡아 둔다 — 예산 부족은 "검사 못 함" 이지 "이상 없음" 이 아니라서 넉넉해야 한다.
    @setEvalBranchQuota(200_000);
    if (depth > max_depth) @compileError("깊이 상한 도달: " ++ @typeName(T));
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return 0,
    }
    var touched: usize = 0;
    inline for (comptime std.meta.declarations(T)) |decl| {
        // **값을 읽지 않는다.** `@TypeOf` 는 comptime 값을 요구하지 않는데 `@field` 로 값을 꺼내면
        // `pub var` 에서 "unable to resolve comptime value" 로 막힌다 — Windows 플랫폼 파일들이
        // `pub var last_hresult` 같은 진단 변수를 갖고 있어 그것들이 표면에 들어오는 순간 걸렸다.
        // 타입 선언만 값이 필요하고 나머지는 아래에서 **주소만** 잡으면 된다(그게 분석을 강제한다).
        const FieldType = @TypeOf(@field(T, decl.name));
        if (FieldType == type) {
            touched += refAllRecursive(@field(T, decl.name), depth + 1);
        } else {
            // 주소를 잡으면 함수는 본문이 분석되고, 그 외 값은 그대로 참조된다.
            _ = &@field(T, decl.name);
            touched += 1;
        }
    }
    return touched;
}

/// 훑어야 하는 선언 수의 **하한**. **실측 2,937 개**(2026-08-19)이고 하한은 그보다 약 32% 낮다 —
/// 코드가 줄어드는 정상 변화로는 안 걸리고, walker 가 비거나 네임스페이스가 통째로 빠지면 걸린다.
///
/// **이 숫자가 없으면 게이트를 조용히 무력화할 수 있다** — `refAllRecursive` 호출을 지워도
/// `check-targets` 가 초록이었다(적대적 검증 12 라운드 실측). "검사했다" 와 "검사할 것이 없었다" 가
/// 구분되지 않는 부류다.
const min_touched = 2000;

test "중립 표면의 공개·비제네릭 선언이 이 타깃으로 컴파일된다" {
    // **`maru.zig` 에서 유도한다.** 모듈 이름을 여기 손으로 나열했더니 21 개 중 14 개가 빠져 있었다
    // (적대적 검증이 잡았다). walker 가 `maru.zig` 에 등록돼 있지 않으므로 순환이 아니다.
    const touched = comptime refAllRecursive(@import("maru.zig"), 0);
    // **컴파일 타임에 세운다.** `check-targets` 는 Run 없이 **컴파일만** 하므로 런타임
    // `expect` 는 그 게이트에서 한 번도 안 돈다 — 하한을 999999 로 올려도 초록이었다(실측).
    comptime {
        if (touched < min_touched) @compileError(std.fmt.comptimePrint(
            "훑은 선언이 {d} 개뿐이다(하한 {d}). walker 가 비었거나 네임스페이스가 통째로 빠졌다.",
            .{ touched, min_touched },
        ));
    }
}
