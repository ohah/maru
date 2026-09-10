//! 이미지 **문맥 복원** — 「이 이미지가 무엇이었는지」를 한 줄로 — 계약 [docs/agent-image-gallery.md](../../docs/agent-image-gallery.md) §2.2.
//!
//! 순수 계산이다. 파일을 열지 않고, 호출자가 읽어 준 두 조각만 본다:
//!
//! - `image_line_prefix` — 이미지가 든 줄의 시작부터 **base64 시작 전까지**. payload 는 수 MB 라
//!   절대 넘겨받지 않는다.
//! - `prev_lines` — 그 앞의 **줄 몇 개**(없으면 빈 슬라이스). 줄로 쪼개 뒤에서부터 본다.
//!
//! ## 왜 직전 줄 하나인가 (2026-08-29 실측, 실제 트랜스크립트 2,548 파일)
//!
//! 초안은 «±6줄 창» 을 적어 두었고, 그 전에는 «같은 줄 앞부분» 으로 충분할 줄 알았다. 둘 다 실측이
//! 깼다 — 같은 줄만 보면 **11.0%** 만 라벨이 나온다(Claude 이미지의 89% 가 `tool_result` 레코드이고
//! 그 줄에는 경로도 텍스트도 없다). 구조를 따라가 보니 답은 한 곳에 있었다:
//!
//! | 잰 것 | 값 |
//! | --- | --- |
//! | `tool_use_id` → assistant `tool_use` 매칭 | 1,074 / 1,074 = **100%** |
//! | 그 레코드가 **몇 줄 뒤**인가 | **언제나 1줄** (누적 100%) |
//! | 그 줄의 `tool_use` 블록 개수 | **언제나 1개** (짝을 고를 필요가 없다) |
//! | `input.file_path` 가 있는 비율 | 1,072 / 1,074 |
//! | `tool_use_id` 가 base64 **앞**에 오는 비율 | 1,076 / 1,076 |
//! | 직전 줄 크기 | 중앙 1.5 KB, 최대 2.3 KB |
//!
//! 그래서 id 맵이 없다. 그리고 마지막 줄(직전 줄 크기)이 «호출자가 64 KiB 만 거슬러 읽으면 된다» 를
//! 정한다 — 실측 최대의 28배 여유다.
//!
//! ## Codex 는 «직전 줄 하나» 가 아니다 (2026-08-30 실측)
//!
//! Claude 는 언제나 1줄 뒤였지만 Codex 의 `view_image` 는 다르다:
//!
//! | 잰 것 | 값 |
//! | --- | --- |
//! | `view_image` 결과 레코드 | 16 |
//! | 그 줄에 텍스트가 **없는** 것 | 13 — 옛 규칙으로는 **빈 라벨** |
//! | 호출이 **2줄 뒤** | 12 |
//! | 호출이 1줄 뒤 | 4 |
//! | 호출 줄에 `payload.path` | 13 |
//!
//! 그래서 창을 «앞선 줄들» 로 넓히고, **id 가 든 줄 안에서만** 경로를 뽑는다. 창을 통째로 훑어
//! `path` 를 집으면 id 는 A 레코드에서, 경로는 B 레코드에서 나올 수 있다 — 그것이 바로 이 모듈이
//! 처음부터 막으려던 «틀린 라벨» 이다.
//!
//! **그래도 id 를 대조한다.** 「언제나 1개」에 기대어 직전 줄의 `file_path` 를 그냥 집으면, 그 가정이
//! 깨지는 날 **엉뚱한 파일 이름**이 이미지에 붙는다. 빈 라벨은 아무 말도 안 하지만 틀린 라벨은
//! 거짓말이다.

const std = @import("std");

/// 라벨 상한. 도크 한 줄에 들어갈 길이면 충분하고, 렌더러가 다시 줄인다(ellipsize).
pub const max_label_bytes: usize = 160;

/// 이미지 줄에서 이 바이트까지만 본다. `tool_use_id` 는 레코드 머리에 있으므로(실측 100%) 넉넉하다.
pub const max_prefix_bytes: usize = 64 * 1024;

/// 직전 줄을 거슬러 읽을 때의 상한. 실측 최대 2.3 KB 의 28배.
pub const max_prev_line_bytes: usize = 64 * 1024;

/// 라벨이 **어디서** 왔는가. 표시가 아니라 진단·테스트용이다 — 규칙이 조용히 다른 갈래로 새면
/// 「라벨은 나오는데 엉뚱하다」가 되는데, 그 차이는 문자열만 봐서는 안 보인다.
pub const Source = enum {
    /// 직전 줄의 `tool_use.input.file_path` — 에이전트가 읽은 이미지.
    tool_file_path,
    /// 같은 줄의 사용자 텍스트 — 붙여넣은 이미지.
    message_text,
    /// codex `<image … path="…">` 래퍼의 경로. 질문 텍스트가 없을 때만.
    codex_wrapper_path,
    none,
};

pub const Label = struct {
    buf: [max_label_bytes]u8 = undefined,
    len: usize = 0,
    source: Source = .none,
    /// 같은 메시지에 붙은 여러 장 중 몇 번째인가(`agent_image_index.sequenceAt`). **0 이면 안 그린다.**
    ///
    /// 라벨을 만드는 쪽(스캐너)은 이 값을 못 채운다 — 이웃 hit 을 봐야 알 수 있는데 스캐너는 한 장씩
    /// 만든다. 그래서 목록이 다 모인 뒤 갤러리가 채운다. 그 전까지는 0 이고, 0 은 「모른다」가 아니라
    /// 「그리지 않는다」이므로 미완성 상태가 화면에 거짓말을 하지 않는다.
    seq: u16 = 0,
    seq_total: u16 = 0,
    /// 이 이미지가 트랜스크립트에 적힌 **시각**(Unix 초, UTC). **0 이면 모른다** — 그때는 안 그린다.
    ///
    /// 라벨과 한 몸으로 다닌다. 따로 배열을 들면 `hits` 를 건드리는 자리마다 «셋» 을 맞춰야 하고,
    /// 어긋나면 남의 이미지에 남의 시각이 붙는다.
    time_s: i64 = 0,

    pub fn text(self: *const Label) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const Label) bool {
        return self.len == 0;
    }
};

/// 이 라벨이 검색어에 걸리는가. **대소문자를 가리지 않고 부분 일치**다.
///
/// 파일명(`dock-layout.png`)과 사람이 쓴 문장(「이 배치가 이상합니다」)이 한 목록에 섞여 있으므로,
/// 접두사 일치로 좁히면 문장 쪽을 못 찾는다. 반대로 fuzzy 로 넓히면 151 장에서 관계없는 것이 잔뜩
/// 걸린다 — 부분 일치가 그 사이다.
///
/// **빈 검색어는 전부 통과**다(필터가 꺼진 상태와 같다).
///
/// 대소문자 접기는 ASCII 만 한다. 한글에는 대소문자가 없고, 그 밖의 문자를 제대로 접으려면 유니코드
/// 케이스 테이블이 필요한데 이 기능이 그것을 정당화하지 않는다.
/// 활동(도구 호출) 한 건의 라벨. **인덱스가 가리킨 대상 문자열을 사람이 읽는 한 줄로 만든다.**
///
/// 이미지 라벨(`label`)과 달리 **찾을 것이 없다** — 스캐너가 이미 대상의 자리를 정했으므로
/// (`description` → `file_path` → 명령, 활동 뷰 계약 §2.2) 여기서는 그 바이트를 다듬기만 한다.
/// 다듬기는 `writeText` 가 이미 한다: JSON 이스케이프를 풀고, 줄바꿈·탭을 공백으로 접고, 상한에서
/// 자른다. 명령의 52.4% 가 여러 줄이므로 그 접기가 없으면 한 줄 목록이 깨진다.
///
/// `is_path` 면 basename 만 남긴다 — `Read` 의 대상은 절대 경로라 라벨 폭을 통째로 먹는다(이미지
/// 라벨이 같은 이유로 같은 선택을 한다).
pub fn activityLabel(raw: []const u8, is_path: bool) Label {
    var out: Label = .{ .source = .none };
    out.len = writeText(&out.buf, if (is_path) basenameOf(raw) else raw);
    return out;
}

/// 펼침(AV3)이 그리는 **여러 줄 그대로의 본문**. 라벨과 달리 줄바꿈을 접지 않는다.
pub const Block = struct {
    /// `out` 에 쓴 바이트.
    len: usize = 0,
    /// **받는 버퍼**가 모자라 뒤가 잘렸다.
    ///
    /// ⚠️ **이것만으로는 「다 봤나」를 못 판정한다.** 푸는 일은 바이트를 **늘리지 않으므로**
    /// (`\n` 둘→하나 · `\uXXXX` 여섯→넷 이하 · 나머지는 1:1), 호출자가 `out` 을 읽어 온 만큼
    /// 잡아 주면 이 깃발은 **영원히 거짓**이다. 실제로 두 소비자가 그렇게 잡고 있었고, 그래서
    /// 펼침의 「이하 생략」이 **한 번도 안 떴다**(적대적 2회차). 잘림을 물으려면 `complete` 를 본다.
    truncated: bool = false,
    /// chunk 껍데기에서 읽은 **종료 코드**. 없으면 null.
    ///
    /// **왜 여기서 드나**: `exit_code` 는 chunk JSON **안**에만 있어서(실측 chunk 의 **33.9%**)
    /// 껍데기를 벗기면 함께 사라진다 — 계약 §6 이 「그때도 `exit_code` 는 보여야 한다」고 못박은
    /// 자리다. 스캐너가 찾게 하면 결과를 **한 번 더 훑어야** 하는데(§4.2 「자리만 든다」), 푸는
    /// 층은 어차피 그 바이트를 지나가므로 **공짜로** 얻는다.
    exit_code: ?i32 = null,
    /// 값의 **끝(따옴표)까지 봤나.** 거짓이면 준 바이트가 값 도중에 끊긴 것이다 — 읽기 상한에
    /// 걸렸거나 파일이 거기서 끝났거나.
    ///
    /// **여기가 「다 봤나」의 단일 출처다.** 소비자가 각자 「내가 상한만큼 읽었나」로 짐작하면
    /// 규칙이 두 벌이 되고, 값이 마침 상한에 딱 맞을 때 갈린다.
    complete: bool = false,
};

/// JSON 문자열 값의 바이트를 **여러 줄 그대로** 푼다(활동 뷰 계약 §2.4).
///
/// 라벨(`writeText`)과 갈리는 지점이 셋이다:
///
/// ⑴ **줄바꿈을 살린다.** 라벨은 한 줄에 접어야 하니 `\n` 을 공백으로 바꾸지만, 펼침의 값어치는
///    「그때 받은 것 그대로」다(계약 §2.4) — 접으면 diff 도 로그도 못 읽는다.
/// ⑵ **값의 끝에서 멈춘다.** 호출자가 파일에서 창 하나를 읽어 주므로 그 창에는 값 뒤의 JSON 이
///    섞여 있다. 이스케이프 안 된 `"` 가 곧 끝이다.
/// ⑶ **상한에서 자르되 글자를 쪼개지 않는다.** 반쪽 UTF-8 은 렌더러가 깨진 글자를 그린다.
///
/// 제어문자는 버린다(`\u001b` 같은 것). 터미널이 아니라 chrome 텍스트라 그대로 실으면 글자가 아니라
/// 쓰레기가 된다 — 라벨이 같은 이유로 같은 선택을 한다.
pub fn unescapeBlock(out: []u8, raw: []const u8) Block {
    const run = unescapeValue(out, raw);
    return .{ .len = run.written, .truncated = run.truncated, .complete = run.closed };
}

/// 값 하나를 푸는 **한 걸음**. `unescapeBlock` 과 `unescapeTextArray` 가 이것을 공유한다 —
/// 규칙이 두 벌이 되면 「배열이면 다르게 풀린다」가 되고, 그건 사용자가 못 볼 어긋남이다.
const ValueRun = struct {
    /// `out` 에 쓴 바이트.
    written: usize = 0,
    /// **입력에서 지나간 바이트** — 닫는 따옴표를 포함한다. 배열 걷기가 다음 자리를 여기서 얻는다.
    consumed: usize = 0,
    /// 닫는 따옴표를 봤나(= 이 값을 끝까지 봤나).
    closed: bool = false,
    truncated: bool = false,
};

fn unescapeValue(out: []u8, raw: []const u8) ValueRun {
    var w: usize = 0;
    var i: usize = 0;
    var complete = false;
    while (i < raw.len) {
        var cp_buf: [4]u8 = undefined;
        var chunk: []const u8 = undefined;
        if (raw[i] == '"') {
            complete = true; // 이스케이프 안 된 따옴표 = 값의 끝 — **여기까지 왔으면 다 본 것이다**
            i += 1;
            break;
        }
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const c = raw[i + 1];
            i += 2;
            switch (c) {
                // **줄바꿈·탭은 살린다** — 여기가 라벨과 갈리는 자리다.
                'n' => chunk = "\n",
                't' => chunk = "\t",
                'r', 'b', 'f' => continue, // 화면에 뜻이 없다
                'u' => {
                    const cp = parseHex4(raw, i) orelse continue;
                    i += 4;
                    if (cp < 0x20) continue; // 제어문자는 버린다
                    const n = std.unicode.utf8Encode(@intCast(cp), &cp_buf) catch continue;
                    chunk = cp_buf[0..n];
                },
                else => {
                    cp_buf[0] = c;
                    chunk = cp_buf[0..1];
                },
            }
        } else {
            const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
                i += 1;
                continue; // 손상된 바이트는 버린다
            };
            if (i + n > raw.len) break;
            chunk = raw[i .. i + n];
            i += n;
            if (chunk.len == 1 and chunk[0] < 0x20 and chunk[0] != '\n' and chunk[0] != '\t') continue;
        }
        // **글자 단위로만 쓴다.** 남는 자리가 이 글자보다 작으면 아예 안 쓰고 잘렸다고 말한다.
        if (w + chunk.len > out.len) return .{ .written = w, .consumed = i, .truncated = true };
        @memcpy(out[w..][0..chunk.len], chunk);
        w += chunk.len;
    }
    return .{ .written = w, .consumed = i, .closed = complete };
}

/// JSON **배열** 안의 `"text"` 값들을 **순서대로 이어** 푼다(활동 뷰 계약 §2.4).
///
/// **왜 필요한가 — 실측이 요구했다.** Codex 의 `custom_tool_call_output` 은 `output` 이 배열이고
/// (2026-09-09 실측 151,914 건 중 **99.9%** 가 원소 둘 이상), 첫 원소는 **99.0%** 가
/// `Script completed / Wall time / Output:` 머리말이다. 첫 원소만 읽으면 결과 텍스트의
/// **0.8%** 만 보게 되고, 실제 명령 출력이 든 둘째 원소부터가 통째로 사라진다.
///
/// **이음매는 「앞이 개행으로 안 끝났을 때만」 가른다.** 실측(2026-09-09, 이음매 181,927)이 셋으로
/// 갈랐다 — ⑴ **93.73%** 는 앞이 개행으로 끝나므로 **넣으면 빈 줄이 생긴다** ⑵ **0.61%** 는 한쪽이
/// 빈 원소라 붙을 것이 없다 ⑶ **5.66%** 는 앞이 Codex 의 chunk 꼬리표(`{"chunk_id":…,"exit_code":0}`)
/// 로 개행 없이 끝나고 뒤에 새 내용이 오므로, **안 넣으면 메타와 내용이 한 줄로 붙는다**.
///
/// ⚠️ 처음에는 「첫 원소가 개행으로 끝나는 비율 100%」만 보고 **아무것도 안 넣기로** 했다. 그 100%
/// 는 **첫 이음매**의 값이고, 모든 이음매로는 93.73% 다 — 첫 표본으로 전체를 일반화한 과장이었다
/// (적대적 3회차). 지금 규칙은 **provider 가 나눈 경계를 화면에서 뭉개지 않는다**는 것이고, 그것은
/// 원소 경계라는 **구조적 사실**의 보존이지 내용의 해석이 아니다(§2.3 과 부딪히지 않는다).
///
/// **머리말을 알아보고 건너뛰지 않는다.** `Script completed` 를 문자열로 판정하는 것은 계약 §2.3
/// (「provider 가 적은 것만 쓴다」)에 어긋난다 — 전부 잇고, 무엇이 잡음인지는 사람이 본다.
///
/// `raw` 는 **여는 `[` 다음**부터다. 문자열 **밖**에서 `]` 를 만나면 끝이다 — 값 안의 `]` 는
/// 이스케이프되지 않으므로(JSON) 문자열 안팎을 실제로 따라가야 한다. 그것이 이 함수가 있는 이유고,
/// 스캐너가 이 일을 안 하는 이유이기도 하다(3.2 GB 를 한 패스 더 지나는 값이 없다 — 소비자는 창
/// 하나만 본다).
/// 객체 안의 **모든 문자열 값**을 이어 푼다 — 호출 입력(`input`) 전용.
///
/// **왜 필요한가**: 검색이 보는 자리는 라벨이 고른 **한 조각**(`description` → `file_path` →
/// 명령)뿐이라, 같은 `input` 안의 다른 필드가 두 층 어디에도 안 걸린다. 실측(2026-09-10 ·
/// Claude tool_use 130,247): `input` 85.5 MB 중 **26.2%(11.2 MB)** 가 그 사각이고, 그중 큰 것이
/// `Write.content` **7.56 MB**(2,552 호출)와 `Edit` 의 `new_string`·`old_string` 2.72 MB 다.
/// 「내가 그때 뭘 써 넣었나」가 정확히 그 물음이다.
///
/// **키는 빼고 값만 잇는다.** 문자열 뒤에 `:` 가 오면 키다 — 키 이름으로 검색이 걸리면
/// `content` 라는 글자가 든 모든 `Write` 가 뜬다.
///
/// 이음매는 `unescapeTextArray` 와 **같은 규율**이다(개행 하나 · 아무것도 안 쓴 값 앞에서는
/// 되돌린다). 두 함수가 갈리면 「배열에서는 붙고 객체에서는 안 붙는」 결과가 나온다.
pub fn unescapeObjectValues(out: []u8, raw: []const u8) Block {
    var w: usize = 0;
    var i: usize = 0;
    // 여는 `{` 를 지난다. 없으면 이 자리는 객체가 아니다.
    while (i < raw.len and raw[i] != '{') : (i += 1) {}
    if (i >= raw.len) return .{ .len = 0 };
    i += 1;
    var depth: usize = 1;
    while (i < raw.len) {
        switch (raw[i]) {
            '{', '[' => {
                depth += 1;
                i += 1;
                continue;
            },
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return .{ .len = w, .complete = true };
                i += 1;
                continue;
            },
            '"' => {},
            else => {
                i += 1;
                continue;
            },
        }
        const str = scanString(raw, i) orelse return .{ .len = w };
        // 뒤에 `:` 가 오면 **키**다 — 값이 아니므로 안 잇는다.
        var j = str.end;
        while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
        if (j < raw.len and raw[j] == ':') {
            i = str.end;
            continue;
        }
        const sep_at = w;
        var wrote_sep = false;
        if (w > 0 and out[w - 1] != '\n') {
            if (w + 1 > out.len) return .{ .len = w, .truncated = true };
            out[w] = '\n';
            w += 1;
            wrote_sep = true;
        }
        const run = unescapeValue(out[w..], raw[str.start..]);
        if (wrote_sep and run.written == 0) w = sep_at else w += run.written;
        if (run.truncated) return .{ .len = w, .truncated = true };
        if (!run.closed) return .{ .len = w }; // 창이 값 도중에 끝났다 — 다 못 봤다
        i = str.start + run.consumed;
    }
    return .{ .len = w }; // 닫는 `}` 를 못 보고 창이 끝났다
}

/// chunk 껍데기를 벗긴 뒤의 결과.
const FoldedChunks = struct {
    /// 벗긴 뒤의 길이.
    len: usize,
    /// 마지막으로 본 `exit_code`. **없으면 null** — 실측 chunk 의 33.9% 에만 있다.
    exit_code: ?i32 = null,
};

/// **`{"chunk_id":…}` 껍데기를 벗기고 그 안의 `output` 만 남긴다** — 제자리에서 줄인다.
///
/// **왜 벗기나**: Codex 는 결과를 chunk 로 잘라 보내는데, 실제 출력이 그 JSON 의 `output` 값
/// **안에** 있다. 그래서 펼치면 `{"chunk_id":"003f2e","wall_time_seconds":0.10,…}` 가 먼저 뜨고
/// 사용자가 보려던 출력은 그 뒤에 묻힌다. 실측(2026-09-10 · Codex 결과 266,470 · 1,144.9 MB):
/// chunk JSON **74,980 개** · 껍데기 14.4 MB(1.26%) · **그 안에 갇힌 실제 출력 191.5 MB(16.73%)**.
///
/// ⚠️ **지우는 것이 아니라 벗기는 것이다**(§2.3). 앞선 두 슬라이스(Codex JS 껍데기 · 옛 형식
/// `input` JSON)와 같은 축이고, 여기는 이스케이프가 **한 겹 더** 있다 — 파일 JSON 한 겹을 이미
/// 푼 자리에서 chunk 의 `output` 값을 또 푼다.
///
/// **제자리에서 줄여도 안전한 이유**: 푸는 일은 바이트를 안 늘리고, 쓰는 자리(`w`)가 읽는 자리
/// 보다 **언제나 앞**이다(껍데기 머리가 값보다 먼저다).
fn foldChunks(buf: []u8) FoldedChunks {
    const needle = "{\"chunk_id\":";
    var exit_code: ?i32 = null;
    var w: usize = 0;
    var i: usize = 0;
    while (i < buf.len) {
        const rel = std.mem.indexOfPos(u8, buf, i, needle) orelse break;
        const end = balancedObjectEnd(buf, rel) orelse break; // 안 닫혔다 — 그대로 둔다
        // 껍데기 앞의 바이트는 그대로 옮긴다(머리말 등).
        const keep = buf[i..rel];
        if (w != i) std.mem.copyForwards(u8, buf[w..][0..keep.len], keep);
        w += keep.len;

        const blob = buf[rel..end];
        if (chunkExitCode(blob)) |code| exit_code = code;
        if (findChunkOutput(blob)) |value| {
            // 값은 **또 한 겹** 이스케이프돼 있다 — 여기서 푼다. 제자리에서 왼쪽으로 쓴다.
            const src_start = rel + value.start;
            const run = unescapeValueInPlace(buf, w, src_start, value.len);
            w += run;
        } else {
            // ⚠️ **`output` 이 없으면 그대로 둔다**(실측 640 개 · chunk 의 0.9%). 벗길 것이 없는데
            // 껍데기를 없애면 그것은 **지우는 일**이고 §2.3 이 금한다 — 「받은 것 그대로」가
            // 깨진다. 기존 판정자가 정확히 이 자리를 잡았다.
            if (w != rel) std.mem.copyForwards(u8, buf[w..][0..blob.len], blob);
            w += blob.len;
        }
        i = end;
    }
    const rest = buf[i..];
    if (w != i) std.mem.copyForwards(u8, buf[w..][0..rest.len], rest);
    w += rest.len;
    return .{ .len = w, .exit_code = exit_code };
}

/// `at` 의 `{` 와 짝이 맞는 `}` **다음**. 문자열 안의 괄호는 안 센다. 못 닫으면 null.
///
/// ⚠️ **정규식으로 `[^}]*` 를 쓰면 안 된다**(적대적 1회차). 실측 chunk 의 **12.8%(9,572 개)** 가
/// `output` 값 안에 `}` 를 갖는다(코드·JSON 을 출력한 자리다) — 거기서 잘려 진짜 출력을 껍데기로
/// 세면 측정이 **136 → 191.5 MB** 만큼 틀린다.
///
/// ⚠️ **지금 실데이터에서는 `depth` 세기가 문자열 건너뛰기와 등가다** — chunk 의 키가 전부
/// 스칼라라(`chunk_id`·`wall_time_seconds`·`original_token_count`·`output`·`session_id`·
/// `exit_code`) 중첩 객체가 없기 때문이다. 뮤테이션으로 확인했다(`depth` 를 버리고 첫 `}` 에서
/// 닫아도 판정자가 안 빨개진다). **그래도 둔다** — 진짜 방어는 문자열 건너뛰기이고, `depth` 는
/// 형식에 중첩이 들어오는 날의 몫이다. 없애면 그날 조용히 잘린다.
fn balancedObjectEnd(buf: []const u8, at: usize) ?usize {
    var depth: usize = 0;
    var i = at;
    while (i < buf.len) {
        switch (buf[i]) {
            '"' => {
                i += 1;
                while (i < buf.len) : (i += 1) {
                    if (buf[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (buf[i] == '"') break;
                }
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

/// chunk 안 `"output":"…"` 값의 자리(`blob` 상대). 없으면 null(실측 0.9%).
const ChunkValue = struct { start: usize, len: usize };

fn findChunkOutput(blob: []const u8) ?ChunkValue {
    const key = "\"output\":\"";
    const k = std.mem.indexOf(u8, blob, key) orelse return null;
    const start = k + key.len;
    var i = start;
    while (i < blob.len) : (i += 1) {
        if (blob[i] == '\\') {
            i += 1;
            continue;
        }
        if (blob[i] == '"') return .{ .start = start, .len = i - start };
    }
    return null;
}

/// chunk 안 `"exit_code":N`. 없으면 null — 실측 **33.9%** 에만 있다.
fn chunkExitCode(blob: []const u8) ?i32 {
    const key = "\"exit_code\":";
    const k = std.mem.indexOf(u8, blob, key) orelse return null;
    var i = k + key.len;
    while (i < blob.len and blob[i] == ' ') i += 1;
    var neg = false;
    if (i < blob.len and blob[i] == '-') {
        neg = true;
        i += 1;
    }
    var value: i64 = 0;
    var seen = false;
    while (i < blob.len and blob[i] >= '0' and blob[i] <= '9') : (i += 1) {
        seen = true;
        value = value * 10 + (blob[i] - '0');
        if (value > std.math.maxInt(i32)) return null;
    }
    if (!seen) return null;
    return @intCast(if (neg) -value else value);
}

/// `src` 구간을 풀어 `dst` 자리에 쓴다 — **같은 버퍼 안에서** 왼쪽으로만 옮긴다.
/// 쓴 바이트를 돌려준다.
fn unescapeValueInPlace(buf: []u8, dst: usize, src: usize, len: usize) usize {
    var w = dst;
    var i = src;
    const stop = src + len;
    while (i < stop) {
        var cp_buf: [4]u8 = undefined;
        var chunk: []const u8 = undefined;
        if (buf[i] == '\\' and i + 1 < stop) {
            const c = buf[i + 1];
            i += 2;
            switch (c) {
                'n' => chunk = "\n",
                't' => chunk = "\t",
                'r', 'b', 'f' => continue,
                'u' => {
                    const cp = parseHex4(buf, i) orelse continue;
                    i += 4;
                    if (cp < 0x20) continue;
                    const n = std.unicode.utf8Encode(@intCast(cp), &cp_buf) catch continue;
                    chunk = cp_buf[0..n];
                },
                else => {
                    cp_buf[0] = c;
                    chunk = cp_buf[0..1];
                },
            }
        } else {
            const n = std.unicode.utf8ByteSequenceLength(buf[i]) catch {
                i += 1;
                continue;
            };
            if (i + n > stop) break;
            // ⚠️ 겹치는 복사라 **먼저 읽고** 쓴다.
            var keep: [4]u8 = undefined;
            @memcpy(keep[0..n], buf[i..][0..n]);
            i += n;
            if (n == 1 and keep[0] < 0x20 and keep[0] != '\n' and keep[0] != '\t') continue;
            @memcpy(buf[w..][0..n], keep[0..n]);
            w += n;
            continue;
        }
        @memcpy(buf[w..][0..chunk.len], chunk);
        w += chunk.len;
    }
    return w - dst;
}

pub fn unescapeTextArray(out: []u8, raw: []const u8) Block {
    var w: usize = 0;
    var i: usize = 0;
    var exit_code: ?i32 = null;
    while (i < raw.len) {
        switch (raw[i]) {
            // 문자열 **밖**의 `]` = 배열의 끝 = 다 봤다.
            ']' => return .{ .len = w, .complete = true, .exit_code = exit_code },
            '"' => {},
            else => {
                i += 1;
                continue;
            },
        }
        // 문자열 하나를 지난다. 그것이 `text` 키였고 뒤에 `:` 와 값이 오면 **그 값을 잇는다**.
        const key = scanString(raw, i) orelse return .{ .len = w, .exit_code = exit_code };
        i = key.end;
        if (!std.mem.eql(u8, raw[key.start..key.stop], "text")) continue;
        var j = i;
        while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
        if (j >= raw.len or raw[j] != ':') continue;
        j += 1;
        while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
        if (j >= raw.len or raw[j] != '"') continue;
        // **이음매를 가른다**(위 ⚠️). 앞에 쓴 것이 있고 그것이 개행으로 안 끝났으면 개행 하나.
        // 빈 원소는 아무것도 안 썼으므로 `w` 가 안 변해, 그 앞의 **실제 마지막 글자**를 본다.
        //
        // ⚠️ **아무것도 안 쓴 원소 앞에서는 되돌린다**(적대적 6회차). 구분자를 먼저 쓰고 값을 푸는
        // 순서라, 그 값이 **빈 문자열**이면 없던 개행만 남는다 — 그것이 배열의 마지막이면 결과
        // 끝에 **빈 줄**이 붙는다(실측 258 건 · 0.17%). 「그때 받은 것 그대로」(§2.4)가 아니다.
        const sep_at = w;
        var wrote_sep = false;
        if (w > 0 and out[w - 1] != '\n') {
            if (w + 1 > out.len) return .{ .len = w, .truncated = true, .exit_code = exit_code };
            out[w] = '\n';
            w += 1;
            wrote_sep = true;
        }
        const run = unescapeValue(out[w..], raw[j + 1 ..]);
        // **chunk 껍데기를 여기서 벗긴다**(§2.4). 방금 푼 조각 안에 `{"chunk_id":…}` 가 있으면
        // 그 `output` 만 남긴다 — 실측 191.5 MB(결과의 16.73%)가 그 안에 갇혀 있다.
        const folded = foldChunks(out[w..][0..run.written]);
        if (folded.exit_code) |code| exit_code = code;
        const written = folded.len;
        if (wrote_sep and written == 0) w = sep_at else w += written;
        if (run.truncated) return .{ .len = w, .truncated = true, .exit_code = exit_code };
        if (!run.closed) return .{ .len = w, .exit_code = exit_code }; // 창이 값 도중에 끝났다
        i = j + 1 + run.consumed;
    }
    return .{ .len = w, .exit_code = exit_code }; // `]` 를 못 보고 창이 끝났다
}

/// `raw[at]` 의 여는 따옴표부터 문자열 하나를 지난다. `start`/`stop` 은 **내용**(따옴표 제외),
/// `end` 는 닫는 따옴표 **다음**이다. 닫히지 않으면 `null`.
const StringSpan = struct { start: usize, stop: usize, end: usize };

fn scanString(raw: []const u8, at: usize) ?StringSpan {
    var i = at + 1;
    while (i < raw.len) {
        if (raw[i] == '\\') {
            i += 2;
            continue;
        }
        if (raw[i] == '"') return .{ .start = at + 1, .stop = i, .end = i + 1 };
        i += 1;
    }
    return null;
}

test "chunk 껍데기: `output` 만 남기고 종료 코드를 든다 (§2.4)" {
    // 🔥 **실측 191.5 MB(Codex 결과의 16.73%)가 껍데기 안에 갇혀 있었다**(2026-09-10 ·
    // 결과 266,470 · 1,144.9 MB · chunk JSON 74,980 개 · 껍데기 자체는 14.4 MB 뿐).
    // 펼치면 `{"chunk_id":"003f2e","wall_time_seconds":0.10,…}` 가 먼저 뜨고 보려던 출력은 묻혔다.
    var out: [512]u8 = undefined;
    const raw =
        "{\"type\":\"input_text\",\"text\":\"Script completed\\nOutput:\\n" ++
        "{\\\"chunk_id\\\":\\\"003f2e\\\",\\\"wall_time_seconds\\\":0.1,\\\"exit_code\\\":0," ++
        "\\\"output\\\":\\\"1:import fs\\\\n2:done\\\\n\\\"}\"}]";
    const r = unescapeTextArray(&out, raw);
    try testing.expect(r.complete);
    // 머리말은 그대로, 껍데기 자리에는 **출력만** 남는다.
    try testing.expectEqualStrings("Script completed\nOutput:\n1:import fs\n2:done\n", out[0..r.len]);
    // 껍데기에서 읽은 종료 코드를 든다 — 벗기면서 잃지 않는다(§6).
    try testing.expectEqual(@as(?i32, 0), r.exit_code);
}

test "chunk 껍데기: 값 안의 `}` 에서 안 잘린다 (적대적 1회차)" {
    // 🔥 **정규식 `[^}]*` 로 잡으면 여기서 잘린다.** 실측 chunk 의 **12.8%(9,572 개)** 가
    // `output` 값 안에 `}` 를 갖는다 — 코드나 JSON 을 출력한 자리다. 잘리면 진짜 출력이
    // 껍데기로 세어져 측정이 **136 → 191.5 MB** 만큼 틀린다(내 첫 측정이 그랬다).
    //
    // ⚠️ **짝이 안 맞는 `}` 를 쓴다.** `{ … }` 처럼 짝이 맞으면 괄호만 세도 우연히 통과해
    // **문자열 건너뛰기가 재이지 않는다** — 첫 픽스처가 그랬고 뮤테이션 둘이 안 잡혔다.
    // 코드 출력에서 닫는 괄호만 있는 줄은 흔하다.
    var out: [512]u8 = undefined;
    const raw =
        "{\"type\":\"input_text\",\"text\":\"" ++
        "{\\\"chunk_id\\\":\\\"4ac65d\\\",\\\"exit_code\\\":1," ++
        "\\\"output\\\":\\\"12:    }\\\\n13:}\\\\n\\\"}\"}]";
    const r = unescapeTextArray(&out, raw);
    try testing.expect(r.complete);
    try testing.expectEqualStrings("12:    }\n13:}\n", out[0..r.len]);
    try testing.expectEqual(@as(?i32, 1), r.exit_code);
}

test "chunk 껍데기: `output` 이 없으면 **그대로 둔다** — 벗기기는 지우기가 아니다 (§2.3)" {
    // 실측 **640 개(chunk 의 0.9%)** 가 `output` 없이 온다. 벗길 것이 없는데 껍데기를 없애면
    // 그것은 **지우는 일**이다 — 「받은 것 그대로」가 깨진다.
    var out: [256]u8 = undefined;
    const raw =
        "{\"type\":\"input_text\",\"text\":\"{\\\"chunk_id\\\":\\\"eb14a3\\\",\\\"exit_code\\\":7}\"}]";
    const r = unescapeTextArray(&out, raw);
    try testing.expect(r.complete);
    try testing.expectEqualStrings("{\"chunk_id\":\"eb14a3\",\"exit_code\":7}", out[0..r.len]);
    // 그래도 종료 코드는 읽는다.
    try testing.expectEqual(@as(?i32, 7), r.exit_code);
}

test "chunk 껍데기: 여럿이면 순서대로 잇고 **마지막** 종료 코드를 든다" {
    // 실측: 한 결과에 chunk 가 2 개 4,086 건 · 3 개 626 건 · 6 개 이상 46 건.
    var out: [512]u8 = undefined;
    const raw =
        "{\"type\":\"input_text\",\"text\":\"" ++
        "{\\\"chunk_id\\\":\\\"a\\\",\\\"exit_code\\\":0,\\\"output\\\":\\\"first\\\\n\\\"}" ++
        "{\\\"chunk_id\\\":\\\"b\\\",\\\"exit_code\\\":130,\\\"output\\\":\\\"second\\\"}\"}]";
    const r = unescapeTextArray(&out, raw);
    try testing.expect(r.complete);
    try testing.expectEqualStrings("first\nsecond", out[0..r.len]);
    // **마지막**이 그 호출의 결말이다.
    try testing.expectEqual(@as(?i32, 130), r.exit_code);
}

test "chunk 껍데기: 종료 코드가 없으면 null — 실측 66.1% 가 그렇다" {
    var out: [256]u8 = undefined;
    const raw =
        "{\"type\":\"input_text\",\"text\":\"" ++
        "{\\\"chunk_id\\\":\\\"c\\\",\\\"output\\\":\\\"plain\\\"}\"}]";
    const r = unescapeTextArray(&out, raw);
    try testing.expect(r.complete);
    try testing.expectEqualStrings("plain", out[0..r.len]);
    try testing.expectEqual(@as(?i32, null), r.exit_code);
}

test "펼침 본문: 배열이면 원소들의 text 를 순서대로 잇는다 (Codex 결과)" {
    // **실측이 이 함수를 요구했다**(2026-09-09): Codex `custom_tool_call_output` 의 `output` 은
    // 배열이고 151,914 건 중 **99.9%** 가 원소 둘 이상인데, 첫 원소는 **99.0%** 가
    // `Script completed / Wall time / Output:` 머리말이다. 첫 원소만 읽으면 결과 텍스트의
    // **0.8%** 만 보게 된다.
    var out: [256]u8 = undefined;

    // ⑴ 실측 모양 그대로 — 머리말 + 실제 출력. 앞이 **개행으로 끝나므로 아무것도 안 넣는다**
    //    (이음매의 93.73% 가 이 모양이고, 여기서 넣으면 **빈 줄**이 생긴다).
    const two =
        "{\"type\":\"input_text\",\"text\":\"Script completed\\nOutput:\\n\"}," ++
        "{\"type\":\"input_text\",\"text\":\"src/a.zig:12\\nsrc/b.zig:34\"}]";
    const r2 = unescapeTextArray(&out, two);
    try testing.expect(r2.complete);
    try testing.expect(!r2.truncated);
    try testing.expectEqualStrings(
        "Script completed\nOutput:\nsrc/a.zig:12\nsrc/b.zig:34",
        out[0..r2.len],
    );

    // ⑵ **`text` 가 아닌 원소는 건너뛴다**(이미지 등 — 실측 304 건). 그리고 `type` 값이 문자열이라
    //    키 판정이 값에 걸리면 안 된다.
    const mixed =
        "{\"type\":\"input_image\",\"image_url\":\"data:...\"}," ++
        "{\"type\":\"input_text\",\"text\":\"only this\"}]";
    const rm = unescapeTextArray(&out, mixed);
    try testing.expect(rm.complete);
    try testing.expectEqualStrings("only this", out[0..rm.len]);

    // ⑵-b **앞이 개행으로 안 끝나면 개행 하나로 가른다**(적대적 3회차). 실측 이음매의 **5.66%**
    //    가 이 모양이다 — 앞이 Codex 의 chunk 꼬리표(`{"chunk_id":…,"exit_code":0}`)로 끝나고 뒤에
    //    새 내용이 온다. 안 가르면 **메타와 내용이 한 줄로 붙는다**.
    //
    //    ⚠️ 처음에는 「첫 원소가 개행으로 끝나는 비율 100%」만 보고 아무것도 안 넣기로 했다. 그
    //    100% 는 **첫 이음매**의 값이고 모든 이음매로는 93.73% 다.
    const glued =
        "{\"type\":\"input_text\",\"text\":\"{\\\"chunk_id\\\":\\\"eb14a3\\\"}\"}," ++
        "{\"type\":\"input_text\",\"text\":\"real output\"}]";
    const rg = unescapeTextArray(&out, glued);
    try testing.expect(rg.complete);
    try testing.expectEqualStrings("{\"chunk_id\":\"eb14a3\"}\nreal output", out[0..rg.len]);

    // ⑵-c **빈 원소는 이음매를 만들지 않는다** — 아무것도 안 쓴 원소 뒤에서는 그 앞의 실제
    //    마지막 글자를 본다(실측 0.61%).
    const empty_mid =
        "{\"type\":\"input_text\",\"text\":\"head\\n\"}," ++
        "{\"type\":\"input_text\",\"text\":\"\"}," ++
        "{\"type\":\"input_text\",\"text\":\"tail\"}]";
    const re = unescapeTextArray(&out, empty_mid);
    try testing.expect(re.complete);
    try testing.expectEqualStrings("head\ntail", out[0..re.len]);

    // ⑵-d **마지막 원소가 비면 없던 개행이 안 붙는다**(적대적 6회차). 구분자를 먼저 쓰고 값을
    //    푸는 순서라, 되돌리지 않으면 결과 **끝에 빈 줄**이 생긴다(실측 258 건 · 0.17%).
    const trailing_empty =
        "{\"type\":\"input_text\",\"text\":\"no newline\"}," ++
        "{\"type\":\"input_text\",\"text\":\"\"}]";
    const rte = unescapeTextArray(&out, trailing_empty);
    try testing.expect(rte.complete);
    try testing.expectEqualStrings("no newline", out[0..rte.len]);

    // ⑶ **값 안의 `]` 는 배열의 끝이 아니다.** JSON 은 `]` 를 이스케이프하지 않으므로 문자열
    //    안팎을 실제로 따라가야 한다 — 이 갈래가 「그냥 `]` 를 찾으면 된다」를 기각한다.
    const bracket = "{\"type\":\"input_text\",\"text\":\"arr[0] ]] done\"},{\"type\":\"input_text\",\"text\":\"tail\"}]";
    const rb = unescapeTextArray(&out, bracket);
    try testing.expect(rb.complete);
    try testing.expectEqualStrings("arr[0] ]] done\ntail", out[0..rb.len]);

    // ⑷ **창이 배열 도중에 끝나면 「다 못 봤다」**다(`complete` 거짓) — 소비자가 그때
    //    「이하 생략」·「다 훑지 못했습니다」를 낸다.
    const cut = "{\"type\":\"input_text\",\"text\":\"head\\n\"},{\"type\":\"input_text\",\"text\":\"tail no close";
    // (앞이 개행으로 끝나므로 이음매에 넣는 것이 없다.)
    const rc = unescapeTextArray(&out, cut);
    try testing.expect(!rc.complete);
    try testing.expectEqualStrings("head\ntail no close", out[0..rc.len]);

    // ⑸ 받는 버퍼가 모자라도 「못 봤다」다.
    var tiny: [6]u8 = undefined;
    const rt = unescapeTextArray(&tiny, two);
    try testing.expect(!rt.complete);
    try testing.expect(rt.truncated);
}

test "unescapeBlock: 값의 끝을 봤는지 말한다 — 「다 봤나」의 단일 출처" {
    // ⚠️ **`truncated` 로는 못 묻는다.** 푸는 일은 바이트를 늘리지 않으므로, 소비자가 읽어 온
    // 만큼 `out` 을 잡아 주면 그 깃발은 영원히 거짓이다 — 두 소비자가 실제로 그렇게 잡고 있어
    // 펼침의 「이하 생략」이 한 번도 안 떴다(적대적 2회차).
    var out: [64]u8 = undefined;

    // ⑴ 닫는 따옴표까지 왔다 = 다 봤다.
    const whole = unescapeBlock(&out, "alpha\nbeta\"tail");
    try testing.expect(whole.complete);
    try testing.expect(!whole.truncated);
    try testing.expectEqualStrings("alpha\nbeta", out[0..whole.len]);

    // ⑵ 따옴표를 못 보고 입력이 끝났다 = **못 봤다**. 여기서 `truncated` 는 여전히 거짓이다 —
    //    이 갈래가 정확히 상한에 걸린 조각의 모양이고, 옛 코드가 「다 봤다」로 답하던 자리다.
    const cut = unescapeBlock(&out, "alpha beta");
    try testing.expect(!cut.complete);
    try testing.expect(!cut.truncated);
    try testing.expectEqualStrings("alpha beta", out[0..cut.len]);

    // ⑶ 받는 버퍼가 모자라도 「못 봤다」다.
    var tiny: [4]u8 = undefined;
    const small = unescapeBlock(&tiny, "alpha beta\"");
    try testing.expect(!small.complete);
    try testing.expect(small.truncated);
}

pub fn matches(label_text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (label_text.len < query.len) return false;
    var i: usize = 0;
    while (i + query.len <= label_text.len) : (i += 1) {
        var j: usize = 0;
        while (j < query.len) : (j += 1) {
            if (foldAscii(label_text[i + j]) != foldAscii(query[j])) break;
        } else return true;
    }
    return false;
}

/// 라벨 줄 **왼쪽 접두**(출처 + 순번)를 만든다. 예: `첨부 2/3` · `읽음` · `2/3` · 빈 값.
///
/// **출처를 왜 화면에 내는가**: `Source` 는 오래 진단·테스트 전용이었고, 그동안 사용자는 「이 텍스트가
/// 내가 올린 것인지 에이전트가 읽은 것인지」를 라벨 **모양**(파일명이냐 문장이냐)으로 짐작해야 했다.
/// 그것은 규약이 아니라 우연한 상관이라, 사용자가 경로를 적어 보낸 순간 틀린다.
///
/// **문자열을 여기서 고르지 않는다.** `origin` 은 호출자가 i18n 테이블에서 뽑아 넘긴다 — 이 모듈은
/// 화면도 언어도 모르는 순수 계산이어야 Linux 에서 그대로 시험된다.
///
/// 순번은 **두 장 이상일 때만** 붙는다(`1/1` 은 알려 주는 것이 없다). `buf` 가 모자라면 붙이지 못한
/// 조각을 조용히 버린다 — 반쪽 숫자(`2/`)를 남기는 것보다 낫다.
pub fn originPrefix(buf: []u8, origin: []const u8, seq: u16, seq_total: u16) []const u8 {
    const has_seq = seq > 0 and seq_total > 1;
    if (origin.len == 0 and !has_seq) return buf[0..0];
    if (origin.len == 0) return std.fmt.bufPrint(buf, "{d}/{d}", .{ seq, seq_total }) catch buf[0..0];
    if (!has_seq) {
        if (origin.len > buf.len) return buf[0..0];
        @memcpy(buf[0..origin.len], origin);
        return buf[0..origin.len];
    }
    return std.fmt.bufPrint(buf, "{s} {d}/{d}", .{ origin, seq, seq_total }) catch blk: {
        if (origin.len > buf.len) break :blk buf[0..0];
        @memcpy(buf[0..origin.len], origin);
        break :blk buf[0..origin.len];
    };
}

/// 라벨 줄의 자리 나누기 — **순수 결정**이라 화면 없이 시험한다. 칸(cols) 단위다.
///
/// 줄은 `[접두] gap [라벨] gap [시각]` 이고, 좁아지면 **시각부터 버린다**. 원래 규율("파일명을 잘라
/// 시계를 넣지 않는다")을 접두까지 넓힌 것이다: 접두가 시각보다 먼저 자리를 얻는 이유는, 이 줄에
/// 사용자가 던지는 첫 물음이 「내가 올린 것인가」이기 때문이다. 그래도 라벨이 `min_label` 아래로
/// 내려가야 한다면 접두 쪽을 포기한다 — 설명이 사라진 줄은 아무 물음에도 답하지 못한다.
pub const RowSplit = struct {
    /// 0 이면 그 조각을 그리지 않는다.
    prefix_cols: u16 = 0,
    label_cols: u16 = 0,
    time_cols: u16 = 0,
};

pub fn splitLabelRow(all_cols: u16, prefix_cols: u16, time_cols: u16, gap: u16, min_label: u16) RowSplit {
    if (all_cols == 0) return .{};
    var out: RowSplit = .{ .label_cols = all_cols };
    if (prefix_cols > 0) {
        // u32 로 올려 더한다 — 셋을 u16 으로 더하면 넘칠 수 있고, 넘치면 「자리가 남는다」로 뒤집힌다.
        const want: u32 = @as(u32, prefix_cols) + gap;
        if (@as(u32, out.label_cols) >= want + min_label) {
            out.prefix_cols = prefix_cols;
            out.label_cols = @intCast(@as(u32, out.label_cols) - want);
        }
    }
    if (time_cols > 0) {
        const want: u32 = @as(u32, time_cols) + gap;
        if (@as(u32, out.label_cols) >= want + min_label) {
            out.time_cols = time_cols;
            out.label_cols = @intCast(@as(u32, out.label_cols) - want);
        }
    }
    return out;
}

/// 활동 **줄 목록**의 자리 나누기 — 격자의 `splitLabelRow` 에 **결과 요약** 한 조각을 더한 판이다.
///
/// 줄은 `[접두] gap [대상] gap [요약] gap [시각]` 이고, 좁아지면 **시각부터, 그다음 요약, 그다음
/// 접두** 순으로 버린다(활동 뷰 계약 §2.2 — 「대상은 마지막까지 지킨다」). 접두가 요약보다 먼저 자리를
/// 얻는 이유는 격자에서 정한 것과 같다: 「전체」에 섞이는 이미지 줄에서 사용자가 던지는 첫 물음이
/// 「내가 올린 것인가」이기 때문이다.
pub const ActivityRowSplit = struct {
    /// 0 이면 그 조각을 그리지 않는다.
    prefix_cols: u16 = 0,
    label_cols: u16 = 0,
    summary_cols: u16 = 0,
    time_cols: u16 = 0,
};

pub fn splitActivityRow(
    all_cols: u16,
    prefix_cols: u16,
    summary_cols: u16,
    time_cols: u16,
    gap: u16,
    min_label: u16,
) ActivityRowSplit {
    if (all_cols == 0) return .{};
    var out: ActivityRowSplit = .{ .label_cols = all_cols };
    // **가져가는 순서가 곧 버리는 순서의 반대다.** 앞엣것이 자리를 먼저 얻는다.
    if (prefix_cols > 0) {
        // u32 로 올려 더한다 — u16 으로 더하면 넘치고, 넘치면 「자리가 남는다」로 뒤집힌다.
        const want: u32 = @as(u32, prefix_cols) + gap;
        if (@as(u32, out.label_cols) >= want + min_label) {
            out.prefix_cols = prefix_cols;
            out.label_cols = @intCast(@as(u32, out.label_cols) - want);
        }
    }
    if (summary_cols > 0) {
        const want: u32 = @as(u32, summary_cols) + gap;
        if (@as(u32, out.label_cols) >= want + min_label) {
            out.summary_cols = summary_cols;
            out.label_cols = @intCast(@as(u32, out.label_cols) - want);
        }
    }
    if (time_cols > 0) {
        const want: u32 = @as(u32, time_cols) + gap;
        if (@as(u32, out.label_cols) >= want + min_label) {
            out.time_cols = time_cols;
            out.label_cols = @intCast(@as(u32, out.label_cols) - want);
        }
    }
    return out;
}

fn foldAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

const tool_use_id_key = "\"tool_use_id\":\"";
const id_key = "\"id\":\"";
const file_path_key = "\"file_path\":\"";
/// Codex `view_image` 는 Claude 와 다른 이름을 쓴다 — 호출 상관 키도, 경로 키도.
const call_id_key = "\"call_id\":\"";
const path_key = "\"path\":\"";
const text_key = "\"text\":\"";
const wrapper_open = "<image ";
const wrapper_path_key = "path=\\\"";

/// 이 이미지의 한 줄 설명. 못 만들면 **빈 라벨**이다 — 지어내지 않는다(계약 1).
pub fn label(image_line_prefix: []const u8, prev_lines: []const u8) Label {
    const prefix = image_line_prefix[0..@min(image_line_prefix.len, max_prefix_bytes)];
    const prev = prev_lines[0..@min(prev_lines.len, max_prev_line_bytes)];

    // ① 에이전트가 읽은 이미지 — 앞선 도구 호출이 그 정체다. provider 마다 키가 다르다.
    //    Claude: `tool_use_id` → `"id"` 가 같은 줄의 `file_path`
    //    Codex : `call_id`     → 그 id 가 든 줄의 `path`
    if (findValue(prefix, tool_use_id_key)) |tid| {
        if (tid.len > 0) {
            if (pathInLineWith(prev, tid, file_path_key)) |raw| {
                var out: Label = .{ .source = .tool_file_path };
                out.len = writeText(&out.buf, basenameOf(raw));
                if (out.len > 0) return out;
            }
        }
    }
    if (findValue(prefix, call_id_key)) |cid| {
        if (cid.len > 0) {
            if (pathInLineWith(prev, cid, path_key)) |raw| {
                var out: Label = .{ .source = .tool_file_path };
                out.len = writeText(&out.buf, basenameOf(raw));
                if (out.len > 0) return out;
            }
        }
    }

    // ② 사용자가 붙여넣은 이미지 — 같은 메시지의 텍스트가 그 정체다.
    //    codex 는 `<image …>` 래퍼와 질문이 **둘 다** `text` 로 들어오므로 래퍼가 아닌 쪽을 고른다.
    var best: ?[]const u8 = null;
    var wrapper: ?[]const u8 = null;
    var i: usize = 0;
    while (findValueFrom(prefix, text_key, i)) |found| {
        i = found.end;
        const raw = found.value;
        if (isWrapper(raw)) {
            if (wrapper == null) wrapper = raw;
            continue;
        }
        if (isClosingTag(raw)) continue;
        if (!isBlank(raw)) best = raw; // 마지막 것이 이긴다 — codex 는 질문이 래퍼 뒤에 온다
    }
    if (best) |raw| {
        var out: Label = .{ .source = .message_text };
        out.len = writeText(&out.buf, stripImageMarkers(raw));
        if (out.len > 0) return out;
    }

    // ③ 질문 없이 이미지만 보낸 codex — 래퍼의 경로라도 말한다.
    if (wrapper) |raw| {
        if (std.mem.indexOf(u8, raw, wrapper_path_key)) |at| {
            const start = at + wrapper_path_key.len;
            const end = std.mem.indexOfPos(u8, raw, start, "\\\"") orelse raw.len;
            var out: Label = .{ .source = .codex_wrapper_path };
            out.len = writeText(&out.buf, basenameOf(raw[start..end]));
            if (out.len > 0) return out;
        }
    }
    return .{};
}

/// 앞선 줄들 중 **그 id 가 든 줄**에서만 경로를 뽑는다. 뒤에서부터 본다(가까운 호출이 그 이미지의 것이다).
///
/// **줄을 넘나들지 않는 것이 핵심이다.** 창을 통째로 훑어 경로를 집으면 id 는 A 레코드에서, 경로는
/// B 레코드에서 나올 수 있다 — 빈 라벨은 아무 말도 안 하지만 틀린 라벨은 거짓말이다.
///
/// 창의 첫 줄은 잘려 있을 수 있는데, 잘린 값은 `findValueFrom` 이 닫는 따옴표가 없어 거부한다.
fn pathInLineWith(prev: []const u8, id: []const u8, key: []const u8) ?[]const u8 {
    var end: usize = prev.len;
    while (end > 0) {
        const start = if (std.mem.lastIndexOfScalar(u8, prev[0 .. end - 1], '\n')) |at| at + 1 else 0;
        const line = prev[start .. end - 1 + @intFromBool(prev[end - 1] != '\n')];
        if (lineHasId(line, id)) return findValue(line, key);
        if (start == 0) break;
        end = start;
    }
    return null;
}

/// 그 줄이 이 id 의 레코드인가. `"id":"<v>"` 와 `"call_id":"<v>"` 둘 다 본다 — Claude 는 앞을,
/// Codex 는 뒤를 쓴다.
fn lineHasId(line: []const u8, id: []const u8) bool {
    for ([_][]const u8{ id_key, call_id_key }) |k| {
        var i: usize = 0;
        while (findValueFrom(line, k, i)) |found| {
            i = found.end;
            if (std.mem.eql(u8, found.value, id)) return true;
        }
    }
    return false;
}

const Found = struct { value: []const u8, end: usize };

/// `"key":"…"` 의 **이스케이프 그대로인** 값. 닫는 따옴표는 `\"` 를 건너뛰며 찾는다.
fn findValueFrom(hay: []const u8, key: []const u8, from: usize) ?Found {
    const at = std.mem.indexOfPos(u8, hay, from, key) orelse return null;
    const start = at + key.len;
    var i = start;
    while (i < hay.len) : (i += 1) {
        switch (hay[i]) {
            '\\' => i += 1, // 이스케이프된 한 글자를 건너뛴다(닫는 따옴표를 오인하지 않게)
            '"' => return .{ .value = hay[start..i], .end = i + 1 },
            else => {},
        }
    }
    return null; // 잘린 줄 — 반쪽 값을 쓰지 않는다
}

fn findValue(hay: []const u8, key: []const u8) ?[]const u8 {
    const f = findValueFrom(hay, key, 0) orelse return null;
    return f.value;
}

fn isWrapper(raw: []const u8) bool {
    return std.mem.startsWith(u8, raw, wrapper_open);
}

fn isClosingTag(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "</image>");
}

/// provider 상용구 `[Image #1] ` 를 벗긴다. 사용자가 쓴 말이 아니라 **포장**이고, 160 px 라벨에서
/// 열한 칸을 먹으면 정작 정체가 밀려난다. 여러 개 붙어 오면(`[Image #1] [Image #2] `) 다 벗긴다.
fn stripImageMarkers(text: []const u8) []const u8 {
    var s = text;
    while (std.mem.startsWith(u8, s, "[Image #")) {
        const close = std.mem.indexOfScalar(u8, s, ']') orelse break;
        if (close > 16) break; // `]` 가 멀면 그건 마커가 아니라 본문이다
        var next = s[close + 1 ..];
        while (next.len > 0 and next[0] == ' ') next = next[1..];
        if (next.len == 0) break; // 마커뿐이면 벗기지 않는다 — 빈 라벨보다 낫다
        s = next;
    }
    return s;
}

fn isBlank(raw: []const u8) bool {
    for (raw) |c| {
        if (c != ' ' and c != '\t' and c != 'n' and c != '\\') return false;
    }
    return true;
}

/// 경로의 마지막 조각. **이스케이프 이전** 문자열에서도 `/` 는 그대로라 안전하다.
fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| {
        if (at + 1 < path.len) return path[at + 1 ..];
    }
    return path;
}

/// JSON 이스케이프를 풀고, 연속 공백을 하나로 접고, 상한에서 **글자 경계**로 자른다.
/// 글자 경계를 안 지키면 반쪽 UTF-8 이 남아 렌더러가 깨진 글자를 그린다.
fn writeText(out: []u8, raw: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    var pending_space = false;
    while (i < raw.len) {
        var cp_buf: [4]u8 = undefined;
        var chunk: []const u8 = undefined;
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const c = raw[i + 1];
            i += 2;
            switch (c) {
                'n', 't', 'r', 'b', 'f' => {
                    pending_space = w > 0;
                    continue;
                },
                'u' => {
                    const cp = parseHex4(raw, i) orelse continue;
                    i += 4;
                    // 서로게이트는 짝을 맞춰야 뜻이 선다. 못 맞추면 그 글자를 버린다(깨진 글자보다 낫다).
                    var code: u21 = cp;
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        if (i + 6 <= raw.len and raw[i] == '\\' and raw[i + 1] == 'u') {
                            const lo = parseHex4(raw, i + 2) orelse continue;
                            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                code = 0x10000 + ((@as(u21, cp) - 0xD800) << 10) + (@as(u21, lo) - 0xDC00);
                                i += 6;
                            } else continue;
                        } else continue;
                    } else if (cp >= 0xDC00 and cp <= 0xDFFF) continue;
                    if (isControl(code)) {
                        pending_space = w > 0;
                        continue;
                    }
                    const n = std.unicode.utf8Encode(code, &cp_buf) catch continue;
                    chunk = cp_buf[0..n];
                },
                '"', '\\', '/' => {
                    cp_buf[0] = c;
                    chunk = cp_buf[0..1];
                },
                else => {
                    cp_buf[0] = c;
                    chunk = cp_buf[0..1];
                },
            }
        } else {
            const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
                i += 1;
                continue; // 깨진 바이트는 버린다
            };
            if (i + n > raw.len) break;
            chunk = raw[i .. i + n];
            i += n;
            if (n == 1 and (chunk[0] == ' ' or chunk[0] == '\t' or chunk[0] == '\n' or chunk[0] == '\r')) {
                pending_space = w > 0;
                continue;
            }
        }
        if (pending_space) {
            if (w + 1 > out.len) break;
            out[w] = ' ';
            w += 1;
            pending_space = false;
        }
        if (w + chunk.len > out.len) break; // 글자 **경계**에서 멈춘다
        @memcpy(out[w .. w + chunk.len], chunk);
        w += chunk.len;
    }
    return w;
}

/// 제어문자인가(C0 · DEL · C1). **라벨은 사용자 대화 본문**이라 무엇이든 들어올 수 있고, JSON 은
/// 제어문자를 `\uXXXX` 로 실어 나른다. 그대로 두면 그리기 경로에 코드포인트로 들어가 글자가 아닌
/// 것을 그리려 하고, `U+0000` 은 빈 칸으로 읽혀 **라벨이 거기서 잘린 것처럼** 보인다.
fn isControl(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F);
}

fn parseHex4(raw: []const u8, at: usize) ?u16 {
    if (at + 4 > raw.len) return null;
    return std.fmt.parseInt(u16, raw[at .. at + 4], 16) catch null;
}

// ── 테스트 ─────────────────────────────────────────────────────────────────────
//
// 픽스처는 **실측한 구조**를 따르되 값은 합성이다(사용자 대화를 커밋하지 않는다).

const testing = std.testing;

test "에이전트가 읽은 이미지: 직전 줄의 도구 호출이 정체다" {
    // 실측 구조: tool_result 줄에 `tool_use_id` 가 base64 앞에 오고, 직전 줄이 그 `tool_use` 다.
    const prev =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01AB","name":"Read","input":{"file_path":"/Users/me/shots/screen.png"}}]}}
    ;
    const prefix =
        \\{"type":"user","message":{"content":[{"tool_use_id":"toolu_01AB","type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"
    ;
    const l = label(prefix, prev);
    try testing.expectEqual(Source.tool_file_path, l.source);
    try testing.expectEqualStrings("screen.png", l.text());
}

test "id 가 안 맞으면 라벨을 붙이지 않는다 — 빈 라벨보다 틀린 라벨이 나쁘다" {
    const prev =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_OTHER","name":"Read","input":{"file_path":"/x/other.png"}}]}}
    ;
    const prefix =
        \\{"message":{"content":[{"tool_use_id":"toolu_01AB","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expect(label(prefix, prev).isEmpty());
    // 직전 줄이 아예 없어도 같다.
    try testing.expect(label(prefix, "").isEmpty());
}

test "사용자가 붙여넣은 이미지: 같은 메시지의 텍스트가 정체다" {
    const prefix =
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Image #1] 이 화면 색이 이상해요"},{"type":"image","source":{"type":"base64","data":"
    ;
    const l = label(prefix, "");
    try testing.expectEqual(Source.message_text, l.source);
    // provider 상용구 `[Image #1] ` 는 벗긴다 — 사용자가 쓴 말만 남는다.
    try testing.expectEqualStrings("이 화면 색이 이상해요", l.text());
}

test "codex: 래퍼가 아니라 질문을 고른다" {
    // 실측 구조: `<image …>` 래퍼 · `</image>` 닫기 · 질문이 각각 별개 `input_text` 로 온다.
    const prefix =
        \\{"content":[{"type":"input_text","text":"<image name=[Image #1] path=\"/tmp/pasted-1.png\">"},{"type":"input_text","text":"</image>"},{"type":"input_text","text":"이 배치가 맞나요?"},{"type":"input_image","image_url":"data:image/png;base64,
    ;
    const l = label(prefix, "");
    try testing.expectEqual(Source.message_text, l.source);
    try testing.expectEqualStrings("이 배치가 맞나요?", l.text());
}

test "codex: 질문이 없으면 래퍼의 경로라도 말한다" {
    const prefix =
        \\{"content":[{"type":"input_text","text":"<image name=[Image #1] path=\"/tmp/dropped/pasted-54737-2.png\">"},{"type":"input_text","text":"</image>"},{"type":"input_image","image_url":"data:image/png;base64,
    ;
    const l = label(prefix, "");
    try testing.expectEqual(Source.codex_wrapper_path, l.source);
    try testing.expectEqualStrings("pasted-54737-2.png", l.text());
}

test "이스케이프를 풀고 줄바꿈·연속 공백을 접는다" {
    const prefix =
        \\{"content":[{"type":"text","text":"첫 줄\n\n  둘째   줄 \"따옴표\" 와 \\ 역슬래시"},{"type":"image","source":{"type":"base64","data":"
    ;
    const l = label(prefix, "");
    try testing.expectEqualStrings("첫 줄 둘째 줄 \"따옴표\" 와 \\ 역슬래시", l.text());
}

test "\\u 이스케이프: 짝이 맞는 서로게이트는 살리고 홀로 남은 것은 버린다" {
    // 짝 맞음(U+1F600). 깨진 글자를 그리느니 버리는 편이 낫다는 규율은 홀로 남은 쪽이 지킨다.
    const ok =
        \\{"content":[{"type":"text","text":"웃음 \ud83d\ude00 끝"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("웃음 😀 끝", label(ok, "").text());
    const lone =
        \\{"content":[{"type":"text","text":"홀로 \ud83d 끝"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("홀로 끝", label(lone, "").text());
}

test "상한에서 글자 경계로 자른다 — 반쪽 UTF-8 을 남기지 않는다" {
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    const head = "{\"content\":[{\"type\":\"text\",\"text\":\"";
    @memcpy(buf[0..head.len], head);
    w = head.len;
    while (w + 3 < 1000) : (w += 3) @memcpy(buf[w .. w + 3], "가");
    const tail = "\"},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"";
    @memcpy(buf[w .. w + tail.len], tail);
    w += tail.len;

    const l = label(buf[0..w], "");
    try testing.expect(l.len <= max_label_bytes);
    try testing.expect(l.len > 0);
    try testing.expect(std.unicode.utf8ValidateSlice(l.text()));
    try testing.expectEqual(@as(usize, 0), l.len % 3); // '가' 는 3바이트 — 반쪽이 없다
}

test "아무 단서도 없으면 빈 라벨 — 지어내지 않는다" {
    const prefix =
        \\{"type":"user","message":{"content":[{"tool_use_id":"toolu_X","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expect(label(prefix, "{\"type\":\"assistant\"}").isEmpty());
    try testing.expect(label("", "").isEmpty());
}

test "잘린 값은 쓰지 않는다 — 닫는 따옴표가 없으면 없는 것이다" {
    // 앞부분 상한에 걸려 잘린 줄. 반쪽 텍스트를 라벨로 쓰면 문장이 중간에서 끊긴 채 굳는다.
    const prefix =
        \\{"content":[{"type":"text","text":"여기서 잘린
    ;
    try testing.expect(label(prefix, "").isEmpty());
}

test "provider 상용구 `[Image #N] ` 는 벗긴다 — 사용자가 쓴 말이 아니다" {
    const one =
        \\{"content":[{"type":"text","text":"[Image #1] 이 배치가 이상해요"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("이 배치가 이상해요", label(one, "").text());
    const many =
        \\{"content":[{"type":"text","text":"[Image #1] [Image #2] 둘 다 보세요"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("둘 다 보세요", label(many, "").text());
    // 마커뿐이면 벗기지 않는다 — 빈 라벨보다 「[Image #1]」이라도 낫다.
    const only =
        \\{"content":[{"type":"text","text":"[Image #1]"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("[Image #1]", label(only, "").text());
    // 대괄호가 멀면 마커가 아니라 본문이다.
    const not_marker =
        \\{"content":[{"type":"text","text":"[Image #1 아주 긴 무언가] 뒤"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("[Image #1 아주 긴 무언가] 뒤", label(not_marker, "").text());
}

test "제어문자는 그리기 경로로 새지 않는다 — 공백으로 접는다" {
    // JSON 은 제어문자를 \uXXXX 로 싣는다. 그대로 두면 U+0000 이 빈 칸으로 읽혀 라벨이 거기서
    // 잘린 것처럼 보이고, ESC 는 글자가 아닌 것을 그리려 한다.
    const prefix =
        \\{"content":[{"type":"text","text":"AA \\u001b[31m BB \\u0000 \\u0007 CC"},{"type":"image","source":{"type":"base64","data":"
    ;
    const got = label(prefix, "").text();
    try testing.expect(std.mem.indexOfScalar(u8, got, 0x1b) == null);
    try testing.expect(std.mem.indexOfScalar(u8, got, 0x00) == null);
    try testing.expect(std.mem.indexOfScalar(u8, got, 0x07) == null);
    // 내용은 남는다 — 통째로 버리지 않는다.
    try testing.expect(std.mem.indexOf(u8, got, "AA") != null);
    try testing.expect(std.mem.indexOf(u8, got, "CC") != null);
}

test "codex 가 읽은 이미지: 앞선 `view_image` 호출의 path 가 정체다" {
    // 실측(2026-08-30): `view_image` 결과 16건 중 13건이 그 줄에 텍스트가 없어 옛 규칙으로는 빈 라벨이었다.
    // 그리고 호출이 **2줄 뒤**인 것이 12건이라 「직전 줄 하나」로는 못 잡았다.
    const prev =
        \\{"type":"response_item","payload":{"type":"function_call","call_id":"call_77","name":"view_image","path":"/Users/me/shots/wide.png"}}
        \\{"type":"event_msg","payload":{"type":"token_count","info":{}}}
    ;
    const prefix =
        \\{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_77","output":[{"type":"input_image","image_url":"data:image/png;base64,
    ;
    const l = label(prefix, prev);
    try testing.expectEqual(Source.tool_file_path, l.source);
    try testing.expectEqualStrings("wide.png", l.text());
}

test "id 는 맞는데 경로가 **다른 줄**에 있으면 쓰지 않는다 — 줄을 넘나들지 않는다" {
    // 창을 통째로 훑어 `path` 를 집으면 id 는 A 레코드에서, 경로는 B 레코드에서 나온다.
    // 그것이 이 모듈이 처음부터 막으려던 「틀린 라벨」이다.
    const prev =
        \\{"payload":{"type":"function_call","call_id":"call_77","name":"view_image"}}
        \\{"payload":{"type":"other","path":"/Users/me/shots/NOT-MINE.png"}}
    ;
    const prefix =
        \\{"payload":{"type":"function_call_output","call_id":"call_77","output":[{"type":"input_image","image_url":"data:image/png;base64,
    ;
    try testing.expect(label(prefix, prev).isEmpty());
}

test "여러 호출이 쌓여 있으면 **가까운** 것을 쓴다" {
    const prev =
        \\{"payload":{"type":"function_call","call_id":"call_1","name":"view_image","path":"/a/old.png"}}
        \\{"payload":{"type":"function_call","call_id":"call_2","name":"view_image","path":"/a/near.png"}}
    ;
    const prefix =
        \\{"payload":{"type":"function_call_output","call_id":"call_2","output":[{"type":"input_image","image_url":"data:image/png;base64,
    ;
    try testing.expectEqualStrings("near.png", label(prefix, prev).text());
    // 앞쪽 호출을 가리키면 그것을 쓴다(가까운 것만 보는 게 아니라 **맞는 것**을 본다).
    const prefix1 =
        \\{"payload":{"type":"function_call_output","call_id":"call_1","output":[{"type":"input_image","image_url":"data:image/png;base64,
    ;
    try testing.expectEqualStrings("old.png", label(prefix1, prev).text());
}

test "창의 첫 줄이 잘려 있어도 안전하다 — 반쪽 값을 쓰지 않는다" {
    // 64 KiB 창은 레코드 한가운데서 시작할 수 있다.
    const prev =
        \\path":"/a/truncated
        \\{"payload":{"type":"function_call","call_id":"call_9","name":"view_image","path":"/a/ok.png"}}
    ;
    const prefix =
        \\{"payload":{"type":"function_call_output","call_id":"call_9","output":[{"type":"input_image","image_url":"data:image/png;base64,
    ;
    try testing.expectEqualStrings("ok.png", label(prefix, prev).text());
}

test "검색: 대소문자 없이 부분 일치, 빈 검색어는 전부" {
    // 파일명과 사람이 쓴 문장이 한 목록에 섞여 있다 — 접두사만 보면 문장 쪽을 못 찾는다.
    try testing.expect(matches("dock-layout.png", "dock"));
    try testing.expect(matches("dock-layout.png", "LAYOUT")); // 대소문자 무시
    try testing.expect(matches("dock-layout.png", ".png")); // 가운데·끝도 걸린다
    try testing.expect(matches("이 화면 배치가 이상합니다", "배치"));
    try testing.expect(!matches("dock-layout.png", "sidebar"));
    // 빈 검색어 = 필터 꺼짐.
    try testing.expect(matches("아무거나", ""));
    try testing.expect(matches("", ""));
    // 라벨이 비면(설명을 못 만든 이미지) 검색어가 있는 한 안 걸린다 — 지어내지 않는다.
    try testing.expect(!matches("", "dock"));
    // 검색어가 라벨보다 길면 걸릴 수 없다.
    try testing.expect(!matches("ab", "abc"));
}

test "검색: 한글은 접지 않는다 — 바이트 그대로 본다" {
    // 한글에는 대소문자가 없다. ASCII 접기가 한글 바이트를 건드리면 엉뚱한 것이 걸린다.
    try testing.expect(matches("배치가 이상합니다", "이상"));
    try testing.expect(!matches("배치가 이상합니다", "정상"));
}

/// 시각을 찾을 창 크기(2026-08-30 실측, 위 모듈 주석).
pub const time_window_after: usize = 256;
pub const time_window_before: usize = 16 * 1024;

const timestamp_key = "\"timestamp\":\"";

/// `"timestamp":"2026-08-30T09:13:22.123Z"` → Unix 초. 못 읽으면 **0**(모름).
///
/// **UTC 로만 읽는다.** 두 provider 다 `Z` 로 끝나는 것을 실측으로 확인했고, 오프셋이 붙은 표기는
/// 여기서 0 을 준다 — 틀린 시각을 그리는 것보다 안 그리는 편이 낫다.
pub fn timestampSeconds(window: []const u8) i64 {
    const raw = findValue(window, timestamp_key) orelse return 0;
    return parseIso8601(raw);
}

/// `YYYY-MM-DDThh:mm:ss` 앞부분만 본다(소수 초·`Z` 는 무시). 모양이 어긋나면 0.
pub fn parseIso8601(raw: []const u8) i64 {
    if (raw.len < 19) return 0;
    if (raw[4] != '-' or raw[7] != '-' or raw[13] != ':' or raw[16] != ':') return 0;
    if (raw[10] != 'T' and raw[10] != ' ') return 0;
    const year = twoOrFour(raw[0..4]) orelse return 0;
    const month = twoOrFour(raw[5..7]) orelse return 0;
    const day = twoOrFour(raw[8..10]) orelse return 0;
    const hour = twoOrFour(raw[11..13]) orelse return 0;
    const minute = twoOrFour(raw[14..16]) orelse return 0;
    const second = twoOrFour(raw[17..19]) orelse return 0;
    if (year < 1970 or year > 9999) return 0;
    if (month < 1 or month > 12 or day < 1 or day > 31) return 0;
    if (hour > 23 or minute > 59 or second > 60) return 0; // 윤초 60 을 거절하지 않는다

    // 1970-01-01 부터의 날 수. `std.time.epoch` 의 윤년 규칙을 쓴다.
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += if (std.time.epoch.isLeapYear(y)) 366 else 365;
    var mo: u16 = 1;
    while (mo < month) : (mo += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(@as(u4, @intCast(mo))));
    }
    days += @as(i64, day) - 1;
    return days * std.time.s_per_day + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn twoOrFour(digits: []const u8) ?u16 {
    var v: u16 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

test "시각: 두 provider 의 실제 모양을 읽는다" {
    // Claude(소수 초 3자리)·Codex(소수 초 6자리) 둘 다 `Z` 로 끝난다.
    const claude = "{\"type\":\"user\",\"timestamp\":\"2026-08-30T09:13:22.123Z\"}";
    const codex = "{\"timestamp\":\"2026-08-30T09:13:22.123456Z\",\"payload\":{}}";
    const want: i64 = 1788081202; // 2026-08-30T09:13:22Z
    try std.testing.expectEqual(want, timestampSeconds(claude));
    try std.testing.expectEqual(want, timestampSeconds(codex));
}

test "시각: 모양이 어긋나면 0 — 없는 시각을 지어내지 않는다" {
    try std.testing.expectEqual(@as(i64, 0), timestampSeconds("{}"));
    try std.testing.expectEqual(@as(i64, 0), timestampSeconds("{\"timestamp\":\"어제\"}"));
    try std.testing.expectEqual(@as(i64, 0), timestampSeconds("{\"timestamp\":\"2026-13-01T00:00:00Z\"}")); // 13월
    try std.testing.expectEqual(@as(i64, 0), timestampSeconds("{\"timestamp\":\"1969-12-31T23:59:59Z\"}")); // epoch 이전
    try std.testing.expectEqual(@as(i64, 0), parseIso8601("2026-08-30"));
}

test "시각: 윤년과 연·월 경계를 넘는다" {
    // 2028 은 윤년이라 2-29 가 있다. 하루를 잘못 세면 여기서 걸린다.
    try std.testing.expectEqual(@as(i64, 1835395200), parseIso8601("2028-02-29T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 0), parseIso8601("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 86399), parseIso8601("1970-01-01T23:59:59Z"));
    // 연 경계 — 12-31 다음이 다음 해 01-01 이다.
    const dec = parseIso8601("2026-12-31T23:59:59Z");
    const jan = parseIso8601("2027-01-01T00:00:00Z");
    try std.testing.expectEqual(dec + 1, jan);
}

/// 문맥 한 조각의 상한. 실측 p90 이 178 B 라 넉넉하고, 최대 2,483 B 는 잘린다 —
/// 크게 보기에 몇 줄 띄우는 것이 목적이지 대화를 통째로 옮기는 것이 아니다.
pub const max_context_bytes: usize = 512;

/// 이미지 **앞**에서 가장 가까운, 사람이 읽을 텍스트. 없으면 빈 슬라이스.
///
/// `label` 과 무엇이 다른가: 라벨은 「이게 **무엇**인가」(파일명·붙여넣은 한 줄)이고, 이것은
/// 「그때 **무슨 얘기**였나」다. 도구가 읽은 이미지에서 특히 벌어진다 — 라벨은 `dock.png` 인데
/// 문맥은 「이 화면에서 정렬이 틀어졌어요」 같은 실제 대화다.
///
/// **가장 가까운 것 하나만** 고른다. 여러 개를 이으면 어디서 어디까지가 한 사람의 말인지 알 수 없고,
/// 그 모호함은 「엉뚱한 문맥이 붙었다」로 보인다.
pub fn contextText(prev_lines: []const u8, out: []u8) []const u8 {
    const prev = prev_lines[0..@min(prev_lines.len, max_prev_line_bytes)];
    var at: usize = prev.len;
    // 뒤에서부터 찾는다 — 가장 가까운 것이 그때의 대화다.
    while (std.mem.lastIndexOf(u8, prev[0..at], text_key)) |k| {
        at = k;
        const span = findValueFrom(prev, text_key, k) orelse continue;
        // **너무 짧은 것은 문맥이 아니다.** `""` 나 `"ok"` 는 붙여도 아무것도 안 알려준다.
        if (span.value.len < min_context_bytes) continue;
        const stripped = stripImageMarkers(span.value);
        // **마커뿐이면 문맥이 아니다.** `stripImageMarkers` 는 그때 벗기지 않고 그대로 둔다 —
        // 라벨에서는 그것이 맞다(빈 칸보다 `[Image #1]` 이 낫다). 그러나 여기서는 반대다:
        // 이미 크게 띄운 그림 아래에 「[Image #1]」은 아무것도 안 알려준다. 더 앞을 본다.
        if (isOnlyImageMarker(stripped)) continue;
        const n = writeText(out, stripped);
        if (n >= min_context_bytes) return out[0..n];
    }
    return out[0..0];
}

/// 문맥으로 칠 최소 길이. 이보다 짧으면 붙여도 아무것도 안 알려준다.
const min_context_bytes: usize = 8;

/// 이 텍스트가 이미지 마커(`[Image #1]`)뿐인가. `stripImageMarkers` 가 벗기기를 포기한 모양이다.
fn isOnlyImageMarker(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "[Image #")) return false;
    const close = std.mem.indexOfScalar(u8, text, ']') orelse return false;
    if (close > 16) return false;
    var rest = text[close + 1 ..];
    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];
    return rest.len == 0;
}

test "문맥: 이미지 앞의 가장 가까운 대화를 고른다" {
    var buf: [max_context_bytes]u8 = undefined;
    const prev =
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"먼저 사이드바를 보겠습니다\"}]}}\n" ++
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"이 화면에서 정렬이 틀어졌어요\"}]}}";
    // **가장 가까운 것**(뒤엣것)이어야 한다 — 앞엣것을 고르면 오래된 얘기가 붙는다.
    try std.testing.expectEqualStrings("이 화면에서 정렬이 틀어졌어요", contextText(prev, &buf));
}

test "문맥: 짧은 것은 건너뛰고 그 앞의 뜻 있는 말을 고른다" {
    var buf: [max_context_bytes]u8 = undefined;
    const prev =
        "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"여기 스크린샷을 봐주세요\"}]}}\n" ++
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"네\"}]}}";
    // `"네"` 는 문맥이 아니다 — 붙여도 아무것도 안 알려준다.
    try std.testing.expectEqualStrings("여기 스크린샷을 봐주세요", contextText(prev, &buf));
}

test "문맥: 없으면 빈 값 — 지어내지 않는다" {
    var buf: [max_context_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("", contextText("", &buf));
    try std.testing.expectEqualStrings("", contextText("{\"type\":\"user\"}", &buf));
    // 이미지 표식만 있는 줄도 문맥이 아니다(상용구를 벗기면 남는 것이 없다).
    try std.testing.expectEqualStrings(
        "",
        contextText("{\"type\":\"text\",\"text\":\"[Image #1]\"}", &buf),
    );
}

test "문맥: 상한을 넘으면 자르되 UTF-8 을 깨지 않는다" {
    var buf: [max_context_bytes]u8 = undefined;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(testing.allocator);
    try line.appendSlice(testing.allocator, "{\"type\":\"text\",\"text\":\"");
    var i: usize = 0;
    while (i < 400) : (i += 1) try line.appendSlice(testing.allocator, "한"); // 3 B × 400 = 1,200 B
    try line.appendSlice(testing.allocator, "\"}");

    const got = contextText(line.items, &buf);
    try std.testing.expect(got.len > 0 and got.len <= max_context_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got)); // 잘린 자리가 글자 한가운데가 아니다
}

test "접두: 출처와 순번을 한 조각으로 붙인다" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("첨부 2/3", originPrefix(&buf, "첨부", 2, 3));
    try std.testing.expectEqualStrings("읽음", originPrefix(&buf, "읽음", 0, 0));
    try std.testing.expectEqualStrings("2/3", originPrefix(&buf, "", 2, 3));
    try std.testing.expectEqualStrings("", originPrefix(&buf, "", 0, 0));
}

test "접두: 한 장뿐이면 순번을 붙이지 않는다 — 「1/1」은 소음이다" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("첨부", originPrefix(&buf, "첨부", 1, 1));
    // 순번을 못 정한 경우(묶음이 상한을 넘었다)도 같다 — 출처만 말한다.
    try std.testing.expectEqualStrings("첨부", originPrefix(&buf, "첨부", 0, 3));
}

test "접두: 자리가 모자라면 반쪽 숫자를 남기지 않는다" {
    // `2/` 처럼 잘린 순번은 틀린 정보다. 못 붙이면 출처만, 그것도 못 담으면 빈 값이다.
    var small: [7]u8 = undefined; // "첨부 2/3" = 10 B 라 안 들어간다("첨부" = 6 B 는 들어간다)
    try std.testing.expectEqualStrings("첨부", originPrefix(&small, "첨부", 2, 3));
    var tiny: [2]u8 = undefined;
    try std.testing.expectEqualStrings("", originPrefix(&tiny, "첨부", 2, 3));
    var none: [0]u8 = undefined;
    try std.testing.expectEqualStrings("", originPrefix(&none, "", 2, 3));
}

test "자리 나누기: 넉넉하면 셋을 다 싣는다" {
    const s = splitLabelRow(30, 6, 5, 1, 6);
    try std.testing.expectEqual(@as(u16, 6), s.prefix_cols);
    try std.testing.expectEqual(@as(u16, 5), s.time_cols);
    try std.testing.expectEqual(@as(u16, 17), s.label_cols); // 30 - (6+1) - (5+1)
}

test "자리 나누기: 좁아지면 시각부터 버린다" {
    // 라벨이 최소(6)를 못 지키게 되는 순간 시각이 빠진다 — 접두는 남는다.
    const s = splitLabelRow(14, 6, 5, 1, 6);
    try std.testing.expectEqual(@as(u16, 6), s.prefix_cols);
    try std.testing.expectEqual(@as(u16, 0), s.time_cols);
    try std.testing.expectEqual(@as(u16, 7), s.label_cols);
}

test "자리 나누기: 그래도 모자라면 접두까지 버린다 — 설명이 먼저다" {
    const s = splitLabelRow(10, 6, 5, 1, 6);
    try std.testing.expectEqual(@as(u16, 0), s.prefix_cols);
    try std.testing.expectEqual(@as(u16, 0), s.time_cols);
    try std.testing.expectEqual(@as(u16, 10), s.label_cols);
}

test "자리 나누기: 빈 줄과 없는 조각" {
    try std.testing.expectEqual(RowSplit{}, splitLabelRow(0, 6, 5, 1, 6));
    const s = splitLabelRow(20, 0, 0, 1, 6);
    try std.testing.expectEqual(@as(u16, 0), s.prefix_cols);
    try std.testing.expectEqual(@as(u16, 0), s.time_cols);
    try std.testing.expectEqual(@as(u16, 20), s.label_cols);
}

test "자리 나누기: 큰 값이 넘쳐 「자리가 남는다」로 뒤집히지 않는다" {
    // u16 으로 더하면 65535 + gap 이 감겨 조건이 참이 되고, 라벨 폭이 음수로 돌아간다.
    const s = splitLabelRow(100, 65535, 65535, 1, 6);
    try std.testing.expectEqual(@as(u16, 0), s.prefix_cols);
    try std.testing.expectEqual(@as(u16, 0), s.time_cols);
    try std.testing.expectEqual(@as(u16, 100), s.label_cols);
}

test "활동 라벨: 여러 줄 명령이 한 줄로 접힌다" {
    // 실측: 명령의 52.4% 가 여러 줄이다. 접지 않으면 목록 한 줄이 깨진다.
    const l = activityLabel("cd /tmp\\npython3 - <<'PY'\\nprint(1)\\nPY", false);
    try testing.expectEqualStrings("cd /tmp python3 - <<'PY' print(1) PY", l.text());
}

test "활동 라벨: JSON 이스케이프를 푼다" {
    const l = activityLabel("grep -n \\\"pub fn main\\\" src/main.zig", false);
    try testing.expectEqualStrings("grep -n \"pub fn main\" src/main.zig", l.text());
}

test "활동 라벨: 경로는 basename 만 남는다" {
    const l = activityLabel("/Users/me/work/repo/src/session/agent_image_index.zig", true);
    try testing.expectEqualStrings("agent_image_index.zig", l.text());
}

test "활동 라벨: 상한을 넘겨도 잘려서 들어간다" {
    var long: [512]u8 = undefined;
    @memset(&long, 'x');
    const l = activityLabel(&long, false);
    try testing.expect(l.len > 0);
    try testing.expect(l.len <= max_label_bytes);
}

test "활동 라벨: 빈 대상은 빈 라벨이다 — 지어내지 않는다" {
    const l = activityLabel("", false);
    try testing.expect(l.isEmpty());
}

test "활동 줄 자리: 좁아지면 시각부터, 그다음 요약, 대상은 마지막까지 (AV2)" {
    // 계약 §2.2 의 우선순위를 **순수 층에서** 못박는다 — 화면 없이 시험할 수 있어야 규칙이 하나로 산다.
    const min_label: u16 = 8;
    const gap: u16 = 1;
    // ① 넉넉하면 넷 다 자리를 얻는다.
    {
        const s = splitActivityRow(48, 4, 6, 5, gap, min_label);
        try testing.expectEqual(@as(u16, 4), s.prefix_cols);
        try testing.expectEqual(@as(u16, 6), s.summary_cols);
        try testing.expectEqual(@as(u16, 5), s.time_cols);
        try testing.expectEqual(@as(u16, 48 - 5 - 7 - 6), s.label_cols);
    }
    // ② 시각을 넣으면 대상이 최소 아래로 가는 폭 → **시각부터 버린다**(요약·접두는 남는다).
    {
        const s = splitActivityRow(22, 4, 6, 5, gap, min_label);
        try testing.expectEqual(@as(u16, 4), s.prefix_cols);
        try testing.expectEqual(@as(u16, 6), s.summary_cols);
        try testing.expectEqual(@as(u16, 0), s.time_cols);
        try testing.expectEqual(@as(u16, 10), s.label_cols);
    }
    // ③ 더 좁으면 **요약까지** 버린다. 접두는 격자에서 정한 우선순위대로 남는다.
    {
        const s = splitActivityRow(15, 4, 6, 5, gap, min_label);
        try testing.expectEqual(@as(u16, 4), s.prefix_cols);
        try testing.expectEqual(@as(u16, 0), s.summary_cols);
        try testing.expectEqual(@as(u16, 0), s.time_cols);
        try testing.expectEqual(@as(u16, 10), s.label_cols);
    }
    // ④ 폭이 0 이면 아무것도 안 그린다.
    try testing.expectEqual(@as(u16, 0), splitActivityRow(0, 4, 6, 5, gap, min_label).label_cols);
    // ⑤ **넘침에 뒤집히지 않는다** — u16 으로 더하면 「자리가 남는다」가 된다.
    {
        const s = splitActivityRow(20, std.math.maxInt(u16), std.math.maxInt(u16), std.math.maxInt(u16), gap, min_label);
        try testing.expectEqual(@as(u16, 0), s.prefix_cols);
        try testing.expectEqual(@as(u16, 0), s.summary_cols);
        try testing.expectEqual(@as(u16, 0), s.time_cols);
        try testing.expectEqual(@as(u16, 20), s.label_cols);
    }
}

test "입력 전부: 객체의 **모든 문자열 값**을 잇는다 — 키는 빼고" {
    // 🔥 실측 `input` 85.5 MB 중 **26.2%(11.2 MB)** 가 두 층 어디에도 안 걸렸다.
    // 그중 큰 것이 `Write.content` 7.56 MB 다.
    var out: [256]u8 = undefined;
    const raw =
        \\{"file_path":"/tmp/a.zig","content":"const x = 1;"}, {"type":"text"}
    ;
    const b = unescapeObjectValues(&out, raw);
    try testing.expect(b.complete);
    // 키(`file_path`·`content`)는 안 들어가고 **값 둘**이 개행으로 이어진다.
    try testing.expectEqualStrings("/tmp/a.zig\nconst x = 1;", out[0..b.len]);
}

test "입력 전부: 중첩 객체·배열 안의 값도 잇는다" {
    // `Edit` 의 `edits` 처럼 배열 안에 객체가 오는 도구가 있다 — 깊이로 가르지 않는다.
    var out: [256]u8 = undefined;
    const raw =
        \\{"todos":[{"content":"첫 일","status":"done"}],"note":"끝"}
    ;
    const b = unescapeObjectValues(&out, raw);
    try testing.expect(b.complete);
    try testing.expectEqualStrings("첫 일\ndone\n끝", out[0..b.len]);
}

test "입력 전부: 값 안의 이스케이프를 풀고, 창이 값 도중에 끝나면 「다 못 봤다」" {
    var out: [256]u8 = undefined;
    const raw =
        \\{"content":"줄1\n줄2","tail":"x"}
    ;
    const b = unescapeObjectValues(&out, raw);
    try testing.expect(b.complete);
    try testing.expectEqualStrings("줄1\n줄2\nx", out[0..b.len]);

    // 닫는 `}` 를 못 보면 complete 가 거짓이다 — 「없다」와 「못 봤다」를 가른다.
    const cut =
        \\{"content":"긴 값이 여기서 끊긴다
    ;
    const c = unescapeObjectValues(&out, cut);
    try testing.expect(!c.complete);
}

test "펼침 본문: 줄바꿈을 살리고, 값의 끝에서 멈추고, 제어문자를 버린다 (AV3)" {
    // 라벨(`writeText`)과 갈리는 세 지점을 한 자리에서 못박는다 — 접으면 diff 도 로그도 못 읽는다.
    var buf: [64]u8 = undefined;
    {
        // ⑴ 줄바꿈·탭은 살아 있고, ⑵ 이스케이프 안 된 따옴표에서 멈춘다(그 뒤는 JSON 이다).
        const b = unescapeBlock(&buf, "a\\nb\\tc\",\"call_id\":\"x\"");
        try testing.expectEqualStrings("a\nb\tc", buf[0..b.len]);
        try testing.expect(!b.truncated);
    }
    {
        // ⑶ 이스케이프된 따옴표는 값의 일부다 — 거기서 멈추면 안 된다.
        const b = unescapeBlock(&buf, "say \\\"hi\\\" now\"");
        try testing.expectEqualStrings("say \"hi\" now", buf[0..b.len]);
    }
    {
        // 제어문자는 버린다 — chrome 텍스트라 그대로 실으면 쓰레기가 된다.
        const b = unescapeBlock(&buf, "A\\u001bB\\u0000C\"");
        try testing.expectEqualStrings("ABC", buf[0..b.len]);
    }
}

test "펼침 본문: 상한에서 자르되 글자를 쪼개지 않는다 (AV3)" {
    // 계약 §2.4 의 완료 조건 그대로 — 반쪽 UTF-8 이 남으면 렌더러가 깨진 글자를 그린다.
    {
        var buf: [7]u8 = undefined; // 「한」 3 B × 2 = 6 B 까지만 들어간다
        const b = unescapeBlock(&buf, "한글한글\"");
        try testing.expectEqualStrings("한글", buf[0..b.len]);
        try testing.expectEqual(@as(usize, 6), b.len); // 7 번째 바이트는 **안 쓴다**
        try testing.expect(b.truncated); // 그리고 잘렸다고 말한다
    }
    {
        // 딱 맞으면 잘리지 않았다고 말한다(경계에서 «잘렸다» 를 지어내지 않는다).
        var buf: [6]u8 = undefined;
        const b = unescapeBlock(&buf, "한글\"");
        try testing.expectEqual(@as(usize, 6), b.len);
        try testing.expect(!b.truncated);
    }
}
