//! UI 표시 문자열의 언어별 테이블과 조회 — 어느 facade에도 속하지 않는 **중립 leaf**다
//! (`redact.zig`·`width.zig`와 같은 결). chrome(L3)·session(L2)·config·platform이 전부 import한다.
//!
//! 단일 출처는 [docs/i18n.md](../docs/i18n.md)이고 이 파일은 그 계약의 코드 반영이다. 왜 이 모양인지의
//! 근거는 그 문서에 있으며, 여기 주석은 "코드가 그 결정을 어떻게 지키는가"만 적는다.
//!
//! **왜 중립 leaf인가**(계약 §1.2·§4): 사용자가 읽고 판단하는 한국어 문장의 실제 소유자가
//! `platform/macos/app_session/`이었다. platform에 문자열이 갇혀 있으면 Windows host가 오는 순간 같은
//! 문장을 다시 써야 한다. `app_session`은 macOS 앱 로직이라 통째로 옮길 수 없으므로, **문자열만** 여기로
//! 빼는 것이 번역과 이식성을 동시에 푸는 유일한 길이다.
//!
//! **왜 comptime struct인가**(계약 §3.1): `Table`에 기본값을 주지 않으므로 언어 테이블이 키 하나를
//! 빠뜨리면 `error: missing struct field`로 **컴파일이 멈춘다**. 번역 누락이 런타임까지 살아남지 않는다.
//! 값이 전부 컴파일타임 리터럴이라 언어 전환에 heap이 없고, `command_catalog.Entry`의 "컴파일타임
//! 리터럴을 ABI가 그대로 가리킨다"는 계약도 언어를 바꿔도 유지된다.

const std = @import("std");
const width = @import("width.zig"); // UTF-8 경계 절단(truncateToBoundary) 단일 출처 — 보간 버퍼 부족 처리에 쓴다

/// 지원 언어. 계약 §2가 영어·한국어로 범위를 정했고, 중국어·일본어는 이 enum과 `Table`만 늘리면 확장된다
/// (CJK는 한글과 같은 EAW Wide라 배치 규칙이 그대로 성립한다 — 계약 §6.5).
pub const Lang = enum { en, ko };

/// 표시 문자열의 키 = 이 struct의 필드.
///
/// **기본값을 주지 않는 것이 이 설계의 핵심이다.** 아래 `en`/`ko` 중 하나라도 필드를 빠뜨리면 그 자리에서
/// 컴파일이 멈춘다(`error: missing struct field: <키>`). 키 목록을 손으로 두 벌 유지하지 않도록 `Key`는
/// 이 struct에서 파생한다.
///
/// **이름 규칙**: `<영역>_<의미>`. 영역 접두로 그 키가 어디 것인지 코드에서 읽힌다.
///   - `fp_root_*` — 파일 탐색기 루트 변경·제거·선택의 결과 안내(`app_session/file_panel.zig`)
///   - `set_*` — 세팅 페이지의 배너/토스트(`app_session/settings.zig`·`input.zig`)
pub const Table = struct {
    // ── 파일 탐색기 루트 (I3a 첫 슬라이스) ────────────────────────────────
    // 전부 `reportFileTreeRootOutcome`의 인자로만 쓰인다. 그 함수가 유일한 소비처라
    // 파라미터 타입을 `?Key`로 바꿔 리터럴이 애초에 넘어갈 수 없게 했다(계약 §7.2 1차).
    fp_root_stale_generation: [:0]const u8,
    fp_root_open_failed: [:0]const u8,
    fp_root_identity_unknown: [:0]const u8,
    fp_root_revalidate_alloc_failed: [:0]const u8,
    fp_root_revalidate_start_failed: [:0]const u8,
    fp_root_revalidate_invalid: [:0]const u8,
    fp_root_identity_gone: [:0]const u8,
    fp_root_capability_gone: [:0]const u8,
    fp_root_identity_changed: [:0]const u8,
    fp_root_change_alloc_failed: [:0]const u8,
    fp_root_replace_failed: [:0]const u8,
    fp_root_add_failed: [:0]const u8,
    fp_root_watch_change_failed: [:0]const u8,
    fp_root_rows_change_failed: [:0]const u8,
    fp_root_first_scan_alloc_failed: [:0]const u8,
    fp_root_scan_start_failed: [:0]const u8,
    fp_root_busy_retry: [:0]const u8,
    fp_root_remove_alloc_failed: [:0]const u8,
    fp_root_remove_failed: [:0]const u8,
    fp_root_missing: [:0]const u8,
    fp_root_watch_remove_failed: [:0]const u8,
    fp_root_rows_remove_failed: [:0]const u8,
    fp_root_invalid_path: [:0]const u8,
    fp_root_request_id_exhausted: [:0]const u8,
    fp_root_picker_alloc_failed: [:0]const u8,
    fp_root_validate_busy: [:0]const u8,

    // ── 세팅 페이지 배너/토스트 (I3a 슬라이스 2) ──────────────────────────
    // `settingsMessageOrNotice`(세팅이 열려 있으면 배너, 아니면 토스트)의 인자로만 쓰인다.
    // 그 함수도 단일 sink 라 파라미터를 `Key`로 바꿔 1차 방어를 완성했다.
    set_global_key_not_allowed: [:0]const u8,
    set_global_chord_taken: [:0]const u8,
    set_no_chord_assigned: [:0]const u8,
    set_no_global_chord_assigned: [:0]const u8,
    set_env_format: [:0]const u8,
    set_env_key_empty: [:0]const u8,
    set_chord_parse_failed: [:0]const u8,
    set_macro_format: [:0]const u8,
    set_chord_conflict: [:0]const u8,
    set_macro_overrides_default: [:0]const u8,
    set_macro_line_format: [:0]const u8,
    set_chord_empty: [:0]const u8,
    /// 값이 끼어드는 유일한 항목 — `{0}`에 이미 그 chord 를 쓰는 명령 이름이 들어간다(§6.3 보간).
    set_chord_taken_by: [:0]const u8,
};

pub const en: Table = .{
    .fp_root_stale_generation = "Explorer root changed, so the folder selection was discarded.",
    .fp_root_open_failed = "Cannot open the selected folder.",
    .fp_root_identity_unknown = "Cannot verify the selected folder's identity.",
    .fp_root_revalidate_alloc_failed = "Cannot prepare folder revalidation state.",
    .fp_root_revalidate_start_failed = "Could not start folder revalidation.",
    .fp_root_revalidate_invalid = "Folder revalidation state is not valid.",
    .fp_root_identity_gone = "Folder identity disappeared, so the change was discarded.",
    .fp_root_capability_gone = "Folder verification capability disappeared, so the change was discarded.",
    .fp_root_identity_changed = "The selected folder was replaced during verification, so the change was discarded.",
    .fp_root_change_alloc_failed = "Cannot prepare explorer root change state.",
    .fp_root_replace_failed = "Cannot replace the explorer root.",
    .fp_root_add_failed = "Cannot add the folder to the workspace.",
    .fp_root_watch_change_failed = "Cannot refresh folder watching, so the root change was discarded.",
    .fp_root_rows_change_failed = "Cannot prepare explorer row state, so the root change was discarded.",
    .fp_root_first_scan_alloc_failed = "Cannot prepare the first scan of the verified explorer root.",
    .fp_root_scan_start_failed = "Could not start the verified folder scan, so the change was discarded.",
    .fp_root_busy_retry = "Try again after the file change or folder selection finishes.",
    .fp_root_remove_alloc_failed = "Cannot prepare explorer root removal state.",
    .fp_root_remove_failed = "Cannot remove the explorer root.",
    .fp_root_missing = "The selected explorer root no longer exists.",
    .fp_root_watch_remove_failed = "Cannot refresh folder watching, so the root removal was discarded.",
    .fp_root_rows_remove_failed = "Cannot prepare explorer row state, so the root removal was discarded.",
    .fp_root_invalid_path = "The selected folder path is not valid.",
    .fp_root_request_id_exhausted = "Cannot issue more folder selection request numbers.",
    .fp_root_picker_alloc_failed = "Cannot prepare folder selection state.",
    .fp_root_validate_busy = "Folder verification is busy, so the request could not start.",

    .set_global_key_not_allowed = "This key cannot be registered as a global shortcut",
    .set_global_chord_taken = "This global shortcut is already bound to another action — overwriting",
    .set_no_chord_assigned = "No shortcut is assigned yet",
    .set_no_global_chord_assigned = "No global shortcut is assigned yet",
    .set_env_format = "Environment variables must be in KEY=VALUE form",
    .set_env_key_empty = "The environment variable KEY is empty",
    .set_chord_parse_failed = "Could not read the shortcut notation",
    .set_macro_format = "Macros must be in text:/esc:/ctrl: form",
    .set_chord_conflict = "Could not apply — it conflicts with another shortcut",
    .set_macro_overrides_default = "A macro overrides the default shortcut",
    .set_macro_line_format = "Macros must be in 'chord = text:...' form",
    .set_chord_empty = "The shortcut is empty",
    .set_chord_taken_by = "This shortcut is already bound to '{0}' — overwriting",
};

pub const ko: Table = .{
    .fp_root_stale_generation = "탐색기 루트가 바뀌어 폴더 선택 결과를 취소했습니다.",
    .fp_root_open_failed = "선택한 폴더를 열 수 없습니다.",
    .fp_root_identity_unknown = "선택한 폴더 identity를 확인할 수 없습니다.",
    .fp_root_revalidate_alloc_failed = "폴더 재검증 상태를 준비할 수 없습니다.",
    .fp_root_revalidate_start_failed = "폴더 재검증 작업을 시작하지 못했습니다.",
    .fp_root_revalidate_invalid = "폴더 재검증 상태가 유효하지 않습니다.",
    .fp_root_identity_gone = "폴더 identity가 사라져 변경을 취소했습니다.",
    .fp_root_capability_gone = "폴더 검증 capability가 사라져 변경을 취소했습니다.",
    .fp_root_identity_changed = "선택한 폴더가 검증 중 교체되어 변경을 취소했습니다.",
    .fp_root_change_alloc_failed = "탐색기 루트 변경 상태를 준비할 수 없습니다.",
    .fp_root_replace_failed = "탐색기 루트를 교체할 수 없습니다.",
    .fp_root_add_failed = "작업공간에 폴더를 추가할 수 없습니다.",
    .fp_root_watch_change_failed = "폴더 감시를 갱신할 수 없어 루트 변경을 취소했습니다.",
    .fp_root_rows_change_failed = "탐색기 행 상태를 준비할 수 없어 루트 변경을 취소했습니다.",
    .fp_root_first_scan_alloc_failed = "검증된 탐색기 루트의 첫 scan을 준비할 수 없습니다.",
    .fp_root_scan_start_failed = "검증된 폴더 scan을 시작하지 못해 변경을 취소했습니다.",
    .fp_root_busy_retry = "파일 변경 또는 폴더 선택이 끝난 뒤 다시 시도하세요.",
    .fp_root_remove_alloc_failed = "탐색기 루트 제거 상태를 준비할 수 없습니다.",
    .fp_root_remove_failed = "탐색기 루트를 제거할 수 없습니다.",
    .fp_root_missing = "선택한 탐색기 루트가 더 이상 존재하지 않습니다.",
    .fp_root_watch_remove_failed = "폴더 감시를 갱신할 수 없어 루트 제거를 취소했습니다.",
    .fp_root_rows_remove_failed = "탐색기 행 상태를 준비할 수 없어 루트 제거를 취소했습니다.",
    .fp_root_invalid_path = "선택한 폴더 경로가 올바르지 않습니다.",
    .fp_root_request_id_exhausted = "폴더 선택 요청 번호를 더 발급할 수 없습니다.",
    .fp_root_picker_alloc_failed = "폴더 선택 상태를 준비할 수 없습니다.",
    .fp_root_validate_busy = "폴더 검증 작업이 바빠 요청을 시작하지 못했습니다.",

    .set_global_key_not_allowed = "이 키는 전역 단축키로 등록할 수 없습니다",
    .set_global_chord_taken = "이 전역 단축키는 이미 다른 동작에 묶여 있습니다 — 덮어씁니다",
    .set_no_chord_assigned = "이미 지정된 단축키가 없습니다",
    .set_no_global_chord_assigned = "이미 지정된 전역 단축키가 없습니다",
    .set_env_format = "환경 변수는 KEY=VALUE 형식이어야 합니다",
    .set_env_key_empty = "환경 변수 KEY가 비어 있습니다",
    .set_chord_parse_failed = "단축키 표기를 읽지 못했습니다",
    .set_macro_format = "매크로는 text:/esc:/ctrl: 형식이어야 합니다",
    .set_chord_conflict = "다른 단축키와 충돌해 적용하지 못했습니다",
    .set_macro_overrides_default = "기본 단축키를 매크로가 덮어씁니다",
    .set_macro_line_format = "매크로는 'chord = text:...' 형식이어야 합니다",
    .set_chord_empty = "단축키가 비어 있습니다",
    .set_chord_taken_by = "이 단축키는 '{0}'에 이미 묶여 있습니다 — 덮어씁니다",
};

/// 키 목록은 `Table`에서 **자동 파생**한다 — 손으로 두 벌 유지하면 그 둘이 갈리는 순간 조용히 어긋난다.
pub const Key = std.meta.FieldEnum(Table);

/// 현재 언어. **UI 스레드가 소유한다**(계약 §5.2) — 쓰기는 config 로드·설정 변경 경로에서만이고, 읽기는
/// 문자열을 DrawList로 옮기는 락 아래 구간이다. 렌더 스레드는 이 값을 보지 않고 이미 해석된 슬라이스만
/// 만지므로(문자열이 static이라 언어가 바뀌어도 그 슬라이스는 유효하다) 언어 전환은 **프레임 경계에서만**
/// 일어나고 한 프레임 안에 두 언어가 섞이지 않는다.
///
/// 초기값이 `en`인 이유는 config 로드 **전**에 참조될 수 있기 때문이다. 한국어 사용자가 시작 순간 영어
/// 화면을 스치지 않으려면 로드 완료 전 렌더를 미뤄야 하며, 그 확인은 `ui.language` 배선(I4)이 든다.
var current: Lang = .en;

pub fn setLang(l: Lang) void {
    current = l;
}

pub fn lang() Lang {
    return current;
}

/// 제품 호출부가 쓰는 조회. 인자는 키 하나뿐이라 호출부에 언어를 실어 나르지 않는다.
pub fn t(key: Key) [:0]const u8 {
    return tIn(current, key);
}

/// 언어를 명시하는 조회 — **테스트가 전역을 건드리지 않고** 양쪽 언어를 확인할 때 쓴다.
///
/// `inline else`가 런타임 `key`를 comptime으로 펼쳐 `@field` 접근을 가능하게 한다. 반환 타입
/// `[:0]const u8`은 chrome의 `[]const u8` 소비자로 그대로 coerce되고 ABI가 요구하는 널 종단도 만족해
/// 양쪽에 하나의 타입으로 통한다(계약 §3.1).
pub fn tIn(l: Lang, key: Key) [:0]const u8 {
    const tbl: *const Table = switch (l) {
        .en => &en,
        .ko => &ko,
    };
    return switch (key) {
        inline else => |k| @field(tbl.*, @tagName(k)),
    };
}

// ── 런타임 보간 ─────────────────────────────────────────────────────────
//
// **왜 std.fmt을 못 쓰나**(계약 §6.3): `std.fmt.bufPrint`는 `comptime fmt`를 요구하는데 번역 문자열은
// 언어에 따라 런타임에 고른 값이다. 그대로 넘기면 `error: unable to resolve comptime value`가 난다.
// gettext·i18next가 자체 보간을 갖는 것도 같은 이유다(C `printf`는 런타임 틀을 받으므로 gettext는 그것을
// 그대로 쓴다 — Zig는 못 쓴다).

/// 보간에 끼울 값. **타입 지정자(`{d}`·`{s}`)를 틀에 두지 않는 이유**가 여기 있다 — 타입이 이 union에
/// 이미 있으므로 번역자가 `{s}`를 `{d}`로 잘못 옮기는 실패 모드가 아예 없다.
pub const Arg = union(enum) {
    s: []const u8,
    d: i64,
};

/// `template`의 `{N}`을 `args[N]`으로 치환해 `buf`에 쓰고, 쓴 부분을 돌려준다.
///
/// 문법은 **`{0}`·`{1}` 위치 자리표시자만**이다. 번호가 필요한 이유는 어순이다 — 같은 문장이
/// `"Moved {0} to {1}"`과 `"{1}(으)로 {0}을(를) 옮겼습니다"`처럼 자리를 바꿔야 하고, 순서대로 채우는
/// 방식으로는 그것을 표현할 수 없다.
///
/// **실패해도 에러를 올리지 않는다**(계약 §6.3). 이 자리의 실패는 "번역이 이상하다"이지 앱이 멈출 일이
/// 아니고, 호출부 수백 곳에 에러 처리를 물리면 그 자체가 부채가 된다.
///   - 범위 밖 인덱스(`{9}`인데 인자 2개) → **원문 그대로** 남긴다. 무엇이 잘못됐는지 화면에 보인다.
///   - 자리표시자가 아닌 중괄호(`{abc}`) → 그대로 복사한다.
///   - 버퍼 부족 → UTF-8 경계에서 자른다(`width.truncateToBoundary` — 깨진 바이트를 남기지 않는다).
pub fn format(buf: []u8, template: []const u8, args: []const Arg) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |close| {
                if (std.fmt.parseInt(usize, template[i + 1 .. close], 10)) |idx| {
                    if (idx < args.len) {
                        w += writeArg(buf[w..], args[idx]);
                    } else {
                        // 인자 부족 — 원문을 남겨 번역 실수가 화면에 드러나게 한다.
                        w += appendTruncated(buf[w..], template[i .. close + 1]);
                    }
                    i = close + 1;
                    continue;
                } else |_| {}
            }
        }
        // 자리표시자가 아닌 바이트는 그대로. 여기서 잘리면 더 쓸 공간이 없다는 뜻이라 멈춘다.
        if (w >= buf.len) break;
        buf[w] = template[i];
        w += 1;
        i += 1;
    }
    return buf[0..w];
}

fn writeArg(dst: []u8, arg: Arg) usize {
    switch (arg) {
        .s => |v| return appendTruncated(dst, v),
        .d => |v| {
            // 숫자 포맷의 틀은 리터럴이라 std.fmt을 쓸 수 있다(런타임 틀이 아니다).
            var tmp: [24]u8 = undefined;
            const printed = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return 0;
            return appendTruncated(dst, printed);
        },
    }
}

/// `src`를 `dst`에 쓰되 공간이 모자라면 UTF-8 경계에서 자른다. 쓴 바이트 수를 돌려준다.
fn appendTruncated(dst: []u8, src: []const u8) usize {
    const n = width.truncateToBoundary(src, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

// ── 로케일 판정 ─────────────────────────────────────────────────────────

/// OS가 준 로케일 식별자 → `Lang`.
///
/// **platform은 문자열을 읽어 그대로 넘기고, 해석은 여기서 한다**(계약 §5.1). 표기가 플랫폼마다 다르므로
/// (macOS `NSLocale`은 `ko-KR`, POSIX는 `ko_KR`, 짧게는 `ko`) 언어 부분만 본다. 이 분리가 있어야
/// 판정 규칙이 플랫폼 수만큼 복제되지 않고, 로케일 문자열을 주입해 **OS 없이 테스트**할 수 있다.
///
/// 모르는 값은 `en`으로 떨어진다 — 읽을 수 없는 언어보다 영어가 낫다.
pub fn fromLocale(tag: []const u8) Lang {
    if (tag.len >= 2 and std.ascii.eqlIgnoreCase(tag[0..2], "ko")) {
        // "ko"로 시작해도 구분자가 오지 않으면 다른 언어다(가상의 "kor"류 오탐 방지).
        if (tag.len == 2 or tag[2] == '-' or tag[2] == '_' or tag[2] == '.') return .ko;
    }
    return .en;
}

// ════════════════════════════════════════════════════════════════════════
//  테스트 — 이 파일이 증명하는 것
//
//  터미널에서 왜 중요한가: 이 leaf가 틀리면 **화면의 모든 안내 문장이 함께 틀린다**. 번역 누락은
//  컴파일에 잡히지만(아래 첫 테스트가 그 구조를 고정한다), 조회·보간·로케일 판정의 오류는 런타임에만
//  드러나고 사용자에게는 "앱이 이상한 말을 한다"로 보인다.
// ════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "언어 테이블은 모든 키를 채운다 — 누락은 컴파일에 잡히므로 여기서는 값이 비지 않음을 본다" {
    // `Table`에 기본값이 없어 필드를 빠뜨리면 이 파일이 컴파일되지 않는다. 그 구조가 지켜지는 한
    // 런타임에 남는 실패는 "빈 문자열을 넣었다"뿐이라 그것만 본다.
    inline for (@typeInfo(Table).@"struct".fields) |f| {
        try testing.expect(@field(en, f.name).len > 0);
        try testing.expect(@field(ko, f.name).len > 0);
    }
}

test "tIn: 언어별로 다른 문자열을 준다 — 전역을 건드리지 않는다" {
    const before = lang();
    try testing.expectEqualStrings("Cannot open the selected folder.", tIn(.en, .fp_root_open_failed));
    try testing.expectEqualStrings("선택한 폴더를 열 수 없습니다.", tIn(.ko, .fp_root_open_failed));
    try testing.expectEqual(before, lang()); // tIn은 전역을 읽지도 쓰지도 않는다
}

test "t: 전역 언어를 따른다" {
    const before = lang();
    defer setLang(before);

    setLang(.ko);
    try testing.expectEqualStrings("선택한 폴더를 열 수 없습니다.", t(.fp_root_open_failed));
    setLang(.en);
    try testing.expectEqualStrings("Cannot open the selected folder.", t(.fp_root_open_failed));
}

test "문자열은 static이다 — 언어를 바꿔도 앞서 받은 슬라이스가 살아 있다" {
    // 계약 §3.1: ABI가 포인터를 그대로 들고 있어도 안전하고, 렌더 스레드가 이미 해석된 슬라이스를
    // 만지는 동안 UI 스레드가 언어를 바꿔도 그 슬라이스는 유효하다(§5.2).
    const before = lang();
    defer setLang(before);

    setLang(.ko);
    const held = t(.fp_root_missing);
    setLang(.en);
    try testing.expectEqualStrings("선택한 탐색기 루트가 더 이상 존재하지 않습니다.", held);
    try testing.expectEqual(held.ptr, tIn(.ko, .fp_root_missing).ptr); // 매번 새로 만들지 않는다
    try testing.expectEqual(@as(u8, 0), held[held.len]); // 널 종단 유지(C ABI 요구)
}

test "보간: 위치 자리표시자가 어순이 다른 언어에서 자리를 바꾼다" {
    var buf: [128]u8 = undefined;
    const args = [_]Arg{ .{ .s = "report.md" }, .{ .s = "docs/" } };
    try testing.expectEqualStrings(
        "Moved report.md to docs/",
        format(&buf, "Moved {0} to {1}", &args),
    );
    try testing.expectEqualStrings(
        "docs/(으)로 report.md을(를) 옮겼습니다",
        format(&buf, "{1}(으)로 {0}을(를) 옮겼습니다", &args),
    );
}

test "보간: 숫자 인자" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("7분 전", format(&buf, "{0}분 전", &.{.{ .d = 7 }}));
    try testing.expectEqualStrings("-3 items", format(&buf, "{0} items", &.{.{ .d = -3 }}));
}

test "보간: 인자가 모자라면 원문을 남긴다 — 번역 실수로 앱이 죽지 않는다" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a {9} b", format(&buf, "a {9} b", &.{.{ .s = "x" }}));
}

test "보간: 자리표시자가 아닌 중괄호는 그대로 복사한다" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{abc} 값", format(&buf, "{abc} 값", &.{}));
    try testing.expectEqualStrings("여는 { 만", format(&buf, "여는 { 만", &.{}));
}

test "보간: 버퍼가 모자라면 UTF-8 경계에서 자른다 — 깨진 바이트를 남기지 않는다" {
    // "가"는 3바이트다. 4바이트 버퍼에 "가나"를 넣으면 첫 글자만 남아야 하고,
    // 두 번째 글자의 앞 1바이트가 남아 화면에 U+FFFD가 뜨면 안 된다.
    var small: [4]u8 = undefined;
    const out = format(&small, "{0}", &.{.{ .s = "가나" }});
    try testing.expectEqualStrings("가", out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));

    // 틀의 리터럴 부분도 같은 규율을 따른다(공간이 없으면 멈춘다).
    var tiny: [2]u8 = undefined;
    try testing.expect(std.unicode.utf8ValidateSlice(format(&tiny, "ab{0}", &.{.{ .s = "cd" }})));
}

test "보간: 자리표시자 문법의 경계 — 닫히지 않음·빈 중괄호·음수·거대 인덱스" {
    // 이 케이스들은 번역자가 틀을 잘못 옮겼을 때 실제로 나오는 모양이다. 어느 것도 앱을 멈추면 안 되고,
    // 무엇이 잘못됐는지 화면에 남아야 고칠 수 있다.
    var buf: [64]u8 = undefined;
    const one = [_]Arg{.{ .s = "X" }};
    try testing.expectEqualStrings("a {0", format(&buf, "a {0", &one)); // 닫히지 않음
    try testing.expectEqualStrings("{}", format(&buf, "{}", &one)); // 빈 중괄호
    try testing.expectEqualStrings("{-1}", format(&buf, "{-1}", &one)); // 음수(usize 파싱 실패)
    try testing.expectEqualStrings("{99999999999999999999}", format(&buf, "{99999999999999999999}", &one)); // 오버플로
    try testing.expectEqualStrings("X}", format(&buf, "{0}}", &one)); // 치환 뒤 남은 닫는 괄호
    try testing.expectEqualStrings("", format(&buf, "", &one)); // 빈 틀
    try testing.expectEqualStrings("인자 없음", format(&buf, "인자 없음", &one)); // 자리표시자 없음
}

test "보간: 같은 인자를 여러 번 쓸 수 있다" {
    // 한국어는 조사 때문에 같은 값을 두 번 부르는 문장이 나온다("X는 X다" 류).
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("A와 A", format(&buf, "{0}와 {0}", &.{.{ .s = "A" }}));
}

test "보간: 인자가 하나도 없을 때 자리표시자는 원문으로 남는다" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{0} 값", format(&buf, "{0} 값", &.{}));
}

test "fromLocale: 플랫폼별 표기를 하나로 정규화한다" {
    try testing.expectEqual(Lang.ko, fromLocale("ko"));
    try testing.expectEqual(Lang.ko, fromLocale("ko-KR")); // macOS NSLocale
    try testing.expectEqual(Lang.ko, fromLocale("ko_KR")); // POSIX
    try testing.expectEqual(Lang.ko, fromLocale("ko_KR.UTF-8"));
    try testing.expectEqual(Lang.ko, fromLocale("KO-kr")); // 대소문자 무시
}

test "fromLocale: 모르는 값은 영어로 떨어진다" {
    try testing.expectEqual(Lang.en, fromLocale("en-US"));
    try testing.expectEqual(Lang.en, fromLocale("ja-JP"));
    try testing.expectEqual(Lang.en, fromLocale(""));
    try testing.expectEqual(Lang.en, fromLocale("k"));
    try testing.expectEqual(Lang.en, fromLocale("kor")); // "ko" 접두지만 구분자가 없다
}
