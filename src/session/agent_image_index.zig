//! 에이전트 트랜스크립트(JSONL)에서 **이미지의 위치**를 찾는 순수 모듈 — 계약은
//! [docs/agent-image-gallery.md](../../docs/agent-image-gallery.md) §3·§4가 소유한다.
//!
//! **바이트를 옮기지 않는다.** 이미지 하나가 수 MB인데 인덱스가 그것을 들고 있으면 목록 하나에
//! 수백 MB가 앉는다. 그래서 이 모듈이 돌려주는 것은 `(줄 오프셋, 데이터 오프셋, 길이)`뿐이고,
//! 실제 픽셀은 화면에 보일 때 그 구간만 다시 읽어 디코드한다(§5.2 — 장당 ~20 ms라 어차피 가상화가 강제된다).
//!
//! **왜 JSON 파서를 쓰지 않는가**: 후보를 찾는 데 필요 없다. JSON은 문자열 안의 따옴표를 이스케이프하므로
//! `"type":"image"`(이스케이프되지 않은 따옴표)는 **구조로만** 나타난다 — 본문이 그 글자를 언급해도 파일에는
//! `\"type\":\"image\"`로 들어간다. 실측 오탐 0(엄격 패턴 364 = `grep` 364, §3.2). 파일 하나가 1.6 GB까지
//! 가므로 줄마다 JSON을 파싱하는 비용을 치를 이유가 없다.
//!
//! **플랫폼을 모른다.** `std`만 쓰고 파일을 열지 않는다 — 바이트 슬라이스를 받아 위치를 돌려준다.
//! 그래서 Linux 타깃으로도 컴파일·테스트된다.

const std = @import("std");

/// 한 줄의 상한. 넘으면 그 줄을 **버린다**(잘라서 반쪽 JSON을 만들지 않는다). 아카이브 스캐너와 같은 값이며,
/// 근거도 같다 — Codex `compacted` 레코드가 실측 7.2 MB까지 간다(§4.2).
pub const max_line_bytes: usize = 16 * 1024 * 1024;

pub const Provider = enum { claude, codex };

/// 이미지가 어떤 레코드로 들어 있는가. **표시가 아니라 중복 판정과 문맥 복원에 쓰인다** —
/// `claude_tool_file`은 `claude_image`와 같은 이미지의 2중 저장이라(§4.3) 해시가 같으면 접힌다.
pub const Kind = enum {
    /// Claude `{"type":"image","source":{"type":"base64",…,"data":"…"}}` — user 메시지와 `tool_result` 양쪽.
    claude_image,
    /// Claude `toolUseResult.file.base64` — 바로 위 레코드와 **같은 이미지의 두 번째 사본**.
    claude_tool_file,
    /// Codex `{"type":"input_image","image_url":"data:<mime>;base64,…"}`.
    codex_input_image,
    /// Claude `{"type":"tool_use","id":…,"name":…,"input":{…}}` — 에이전트가 도구를 부른 자리.
    /// MCP 호출도 여기다(이름만 `mcp__서버__도구` 다).
    claude_tool_use,
    /// Codex `payload.type == "custom_tool_call"` 또는 `"function_call"`.
    codex_tool_call,

    pub fn provider(self: Kind) Provider {
        return switch (self) {
            .claude_image, .claude_tool_file, .claude_tool_use => .claude,
            .codex_input_image, .codex_tool_call => .codex,
        };
    }

    /// 그림인가. **디코드·격자·썸네일은 이것만 본다** — 활동 `Hit` 의 `data_offset` 은 base64 가 아니라
    /// 사람이 읽는 문자열을 가리키므로, 가르지 않으면 디코더가 명령문을 PNG 로 열려고 든다.
    pub fn isImage(self: Kind) bool {
        return switch (self) {
            .claude_image, .claude_tool_file, .codex_input_image => true,
            .claude_tool_use, .codex_tool_call => false,
        };
    }
};

/// 활동이 어떤 종류인가 — 화면의 「읽기 / 실행」 필터가 이 값을 본다(계약 §2.1).
///
/// **도구 이름으로만 가른다.** `grep` 을 「읽기」로 옮기려면 명령 문자열을 해석해야 하는데, 파이프·
/// 리다이렉트·서브셸이 섞이면 「읽기인가」에 정답이 없고 그 해석은 규칙이 두 벌이 된다(계약 §2.3).
pub const Activity = enum {
    /// 이미지 `Hit` 이다 — 활동 축이 없다.
    none,
    /// Claude `Read` · Codex `view_image`.
    read,
    /// Claude `Bash` · Codex `exec`/`shell`/`exec_command`/`write_stdin`.
    exec,
    /// 그 밖 전부(Edit·Write·`apply_patch`·MCP·provider 가 새로 만든 도구).
    other,

    /// 도구 이름을 축으로 옮긴다. **모르는 이름은 `other`** — 없는 분류를 지어내지 않는다.
    ///
    /// **이름으로만 가른다**(§2.3). `grep` 이 읽기인지는 명령을 해석해야 알 수 있고, 그러면 규칙이
    /// 두 벌이 된다 — 필터는 도구 이름만 보고 펼침이 「실제로 읽어 낸 텍스트」로 답한다.
    ///
    /// ⚠️ **Codex 어휘가 두 벌이다.** 같은 도구가 세션에 따라 바깥 이름으로 오기도 하고(옛 형식 ·
    /// 실측 117,413 건) JS 껍데기 안쪽 이름으로 오기도 한다(§2.2 · 197,921 건). 표는 **둘 다**
    /// 같은 이름을 보므로 한 벌만 알면 된다.
    ///
    /// 실측(2026-09-10 · Codex 호출 315,334)이 이 표를 정했다 — `exec_command` 152,235 ·
    /// `write_stdin` 82,027 이 실행이고, `apply_patch` 34,785 는 **파일을 고치는 일**이라
    /// Claude 의 `Edit`·`Write` 와 같은 칸(`other`)에 든다.
    pub fn fromToolName(name: []const u8) Activity {
        if (std.mem.eql(u8, name, "Read")) return .read;
        if (std.mem.eql(u8, name, "view_image")) return .read;
        if (std.mem.eql(u8, name, "Bash")) return .exec;
        if (std.mem.eql(u8, name, "exec")) return .exec;
        if (std.mem.eql(u8, name, "shell")) return .exec;
        // Codex 2026-07 어휘 — 껍데기(`exec`)가 아니라 **실제로 돈 도구**의 이름이다.
        if (std.mem.eql(u8, name, "exec_command")) return .exec;
        if (std.mem.eql(u8, name, "write_stdin")) return .exec;
        return .other;
    }
};

/// 인덱스가 아는 mime. 디코드는 ImageIO가 스스로 sniff하므로 **표시와 진단용**이다.
/// 모르는 값을 지어내지 않는다 — 레코드가 안 밝히면 `unknown`이다.
pub const Mime = enum {
    unknown,
    png,
    jpeg,
    gif,
    webp,
    other,

    fn parse(s: []const u8) Mime {
        if (std.mem.eql(u8, s, "image/png")) return .png;
        if (std.mem.eql(u8, s, "image/jpeg") or std.mem.eql(u8, s, "image/jpg")) return .jpeg;
        if (std.mem.eql(u8, s, "image/gif")) return .gif;
        if (std.mem.eql(u8, s, "image/webp")) return .webp;
        if (std.mem.startsWith(u8, s, "image/")) return .other;
        return .unknown;
    }
};

/// 「접힌 곳이 없다」. `Hit.fold_owner` 의 기본값이며, 0 을 쓸 수 없어서(0 은 첫 `Hit` 의 자리다)
/// 상한값을 센티넬로 쓴다.
pub const no_fold: u32 = std.math.maxInt(u32);

/// 이미지 하나의 **자리**. 바이트는 담지 않는다.
pub const Hit = struct {
    /// 이 이미지가 든 줄의 시작(파일 절대). 문맥 복원(§2.2)이 이 값으로 앞뒤 줄을 찾는다.
    line_offset: u64,
    /// base64 payload의 첫 바이트(파일 절대). data URL이면 `,` **다음**을 가리킨다.
    data_offset: u64,
    data_len: u32,
    kind: Kind,
    mime: Mime,
    /// 활동 축(계약 §2.1의 필터). 이미지는 `none` 이다.
    activity: Activity = .none,
    /// 도구 이름의 자리 — **줄 시작으로부터의 상대 오프셋**이다(`line_offset` 을 더하면 파일 절대).
    /// 절대값을 담지 않는 이유는 크기다: 이름은 언제나 같은 줄 안이므로 u32 로 충분하고, `Hit` 이
    /// 12,200개까지 가므로(계약 §4.2) 8 바이트를 아낀다. 이미지는 둘 다 0 이다.
    name_rel: u32 = 0,
    name_len: u16 = 0,
    /// **어느 파일**의 오프셋인가(`Chain` 안 위치). 재개 세션은 부모 rollout 까지 훑으므로(§3.3)
    /// 오프셋만으로는 어느 파일인지 알 수 없다 — 그 값으로 디코드·라벨이 파일을 연다.
    ///
    /// 0 이 현재 세션이다. 스캐너 자신은 이 값을 안 건드린다(파일 하나를 훑을 뿐이다) — 여러 파일을
    /// 이어 담는 호출자가 채운다.
    file_index: u8 = 0,
    /// 이 호출의 **id**(`tool_use_id`/`call_id`)가 줄 안 어디에 있나 — `name_rel` 과 같은 규약이다.
    ///
    /// **호출마다 자기 자리를 든다.** 한 줄에 호출이 둘일 수 있으므로(그 전제 위에서 라벨이 남의 값을
    /// 집던 결함을 이미 고쳤다) 링크도 줄이 아니라 **그 호출의 범위**에서 id 를 얻어야 한다.
    id_rel: u32 = 0,
    id_len: u8 = 0,
    /// **펼침이 보여 줄 명령**의 자리 — 줄 시작 상대(AV3 적대적 검증). **0 이면 대상이 곧 명령이다.**
    ///
    /// ⚠️ 라벨의 대상(`data_offset`)과 **다를 수 있다.** 라벨은 사람이 읽기 좋은 것을 먼저 고르므로
    /// (`description` → `file_path` → 명령, 계약 §2.2) Claude Bash 의 68.8% 에서 대상은 **모델이 쓴
    /// 요약**이다. 그런데 계약 §2.2 는 그 대가를 이렇게 갚기로 했다 — 「`description` 은 명령과 어긋날
    /// 수 있다, **그래서 펼치면 언제나 명령 전문이 먼저 나온다**」. 그 약속을 지키려면 명령의 자리를
    /// 따로 들어야 한다.
    cmd_rel: u32 = 0,
    /// 이 호출이 적힌 **시각**의 자리 — `"timestamp":"` **키**의 줄 시작 상대 오프셋(AV2b).
    /// **0 이면 모른다**(줄은 `{` 로 시작하므로 0 은 키의 자리가 될 수 없다).
    ///
    /// 값을 여기서 파싱하지 않는 이유는 층이다 — ISO 파서는 `agent_image_context` 가 소유하고,
    /// 라벨 패스가 이미 그 모듈을 쓴다. 스캐너는 **자리만** 적는다.
    time_rel: u32 = 0,
    /// **이 이미지가 어느 호출의 결과인가** — 그 호출 `Hit` 의 자리(§2.2.1). 활동이거나 호출을 못
    /// 찾은 이미지는 `no_fold` 다.
    ///
    /// 「전체」가 이 값으로 **접는다**: 결과가 이미지인 호출은 활동 줄과 이미지 항목으로 **두 번**
    /// 뜨는데(실측 542/542 가 그 모양이다), 접으면 한 줄이다. 「이미지」 필터는 그대로 보여 준다 —
    /// 접는 것은 「전체」에서 남의 줄과 겹칠 때뿐이다.
    ///
    /// **자리(인덱스)를 드는 이유**는 「호출이 사라지면 접기도 풀려야」 하기 때문이다. 상한을 넘긴
    /// 파일은 오래된 호출을 버리는데(`evictOldestActivities`), 접힌 채로 두면 그 이미지는 「전체」에서
    /// **통째로 사라진다** — 「없다」와 「못 봤다」를 가르는 계약이 그것을 금한다.
    ///
    /// ⚠️ 그래서 이 값은 **배열이 움직일 때마다 따라 움직여야 한다**: 퇴출(`remapFoldsAfterEvict`)과
    /// 화면이 최신을 앞에 놓으려 뒤집을 때(`agent_activity.applyScan`) 둘이다. 대기 링(`PendingCall`)과
    /// 같은 규율이고, 같은 이유로 판정자가 그 둘을 각각 못박는다.
    fold_owner: u32 = no_fold,
    /// 이 호출이 **어떻게 끝났나**(AV2 — 계약 §2.2·§3.2). 이미지와 결과를 못 찾은 호출은 기본값이다.
    ///
    /// **`Hit` 안에 든다**(라벨처럼 나란한 배열이 아니라). 요약은 **뒤에 오는 줄**에서 만들어져 **앞의
    /// 호출**에 붙으므로, 나란한 배열이면 「스캔 순서대로 append」 규율이 깨져 정렬이 어긋난다.
    result: ResultSummary = .{},
};

/// 호출의 **결말** — 화면의 요약 칸(계약 §2.2)이 읽는 값. **provider 가 쓴 것만 담는다.**
///
/// 실측(2026-09-07, 이 맥의 최근 Claude 12 · Codex 13 세션)이 이 모양을 정했다. 계획 초안은 「결과의
/// **첫 줄**과 크기」였는데, 첫 줄은 대부분 잡음이었다 — Codex 첫 줄의 상위는 `Script completed`
/// (133,852) · `Chunk ID`(14,940) · 파일명이고, 「무엇이 어떻게 끝났나」를 말하는 것은 극히 일부다.
/// 그래서 **크기(줄 수)** 를 언제나 쓰고, **실패**는 provider 가 적었을 때만 말한다(사용자 결정 2026-09-07).
/// 결과 본문의 **자리와 모양**. `ResultSummary` 가 값으로 든다.
pub const ResultBody = struct {
    /// 본문의 첫 바이트(파일 절대). 펼침(AV3)과 본문 검색(§2.1.1)이 그 자리부터 읽는다.
    ///
    /// **바이트를 안 담는다** — 결과는 최대 2.8 MB 이고 세션당 12,200 개다. 자리만 들고 있다가
    /// 읽을 때 그 구간만 보는 것이 계약 §2.4 의 규율이다(라벨·이미지와 같은 결).
    ///
    /// ⚠️ **`is_array` 가 이 값의 뜻을 바꾼다.** 참이면 여는 `[` **다음**이고, 거짓이면 값의 첫
    /// 바이트다. 하나만 읽으면 안 된다.
    offset: u64 = 0,
    /// 본문이 **배열**인가(Codex `output`). 참이면 읽는 쪽이 원소들의 `text` 를 **순서대로 이어야**
    /// 한다(`agent_image_context.unescapeTextArray`).
    ///
    /// **이 사실을 값으로 드는 이유**는 소비자가 바이트를 보고 짐작하지 않게 하려는 것이다 —
    /// 창 첫 글자가 `{` 인지로 가르면 그 규칙이 스캐너와 갈리고, 갈리는 순간 본문이 통째로 빈다.
    is_array: bool = false,
};

pub const ResultSummary = struct {
    /// 결과 레코드를 실제로 찾았나. 못 찾은 호출(취소·아직 안 끝난 것)은 false 이고, 그때 화면은 요약
    /// 자리를 **비운다** — 「모른다」를 「0 줄」로 적지 않는다.
    found: bool = false,
    /// provider 가 **실패라고 적었나.** 우리가 명령이나 출력을 해석해 판정하지 않는다(계약 §2.3).
    /// 근거는 둘뿐이다 — Claude `"is_error":true`(실측 714/40,424), Codex 결과 첫 줄의 `Exit code: N`·
    /// `exit=N`(N≠0).
    failed: bool = false,
    /// 결과 텍스트의 줄 수(개행 + 1). 실측 Claude 중앙 5 · p99 82 · 최대 747.
    lines: u32 = 0,
    /// 결과가 **이미지**였나(§2.2.1). 「전체」가 이 호출로 이미지를 접고, AV5 가 여기에 썸네일을 붙인다.
    ///
    /// **본문이 없는 것과는 다른 사실이다.** Claude 는 `content` 가 이미지 블록만 들어(실측 542/542)
    /// 셀 줄이 없지만, Codex 는 `output` 이 `[{text}, …, {input_image}]` 라 **텍스트가 함께 온다**.
    /// 그래서 화면은 「이미지면 무조건 이미지라고 적는다」가 아니라 **본문이 없을 때만** 그렇게 적는다 —
    /// 아니면 provider 가 적어 준 말을 우리가 지운다.
    ///
    /// **스캐너의 이미지 패스가 이 사실의 유일한 출처다.** 결과 줄을 다시 뒤져 `"type":"image"` 를
    /// 찾지 않는다 — 그러면 「무엇이 이미지인가」의 규칙이 두 벌이 되고, 이 저장소가 반복해서 당한
    /// 형태다. 같은 줄에서 이미지 `Hit` 이 나왔다는 사실을 그대로 쓴다.
    image: bool = false,
    /// 그 그림의 **자리**(AV5) — 접힌 줄에 썸네일을 붙일 때 디코드가 읽을 바이트다.
    /// `image` 가 참일 때만 뜻이 있고, 길이 0 이면 「자리를 모른다」다.
    ///
    /// **자리(인덱스)가 아니라 값이다.** 「그 이미지가 `Hit` 배열의 몇 번째인가」로 들면 배열이
    /// 움직일 때마다 따라가야 하는데(퇴출 · 화면의 뒤집기), 오프셋은 **파일 안에서 변하지 않는다** —
    /// 타일 재연결이 `(file_index, data_offset)` 을 키로 쓰는 것과 같은 이유다. 이 스택에서 그
    /// 「따라가야 하는 필드」를 이미 셋 만들었고(대기 링 · 접기 · 옛 파일 번호), 넷째는 안 만든다.
    image_offset: u64 = 0,
    image_len: u32 = 0,
    /// 그 그림이 **어느 파일**에 있나. 호출과 결과는 같은 파일 안에서만 이어지지만(스캐너가 파일마다
    /// 새로 선다) 값으로 들어 두면 소비자가 그 전제를 몰라도 된다.
    image_file: u8 = 0,
    /// 결과 **본문을 어디서 어떻게 읽나**. 자리와 「배열인가」는 **떼면 안 되는 짝**이라 한 값으로 든다.
    ///
    /// **왜 묶나**(적대적 9회차): 둘이 나란한 필드였을 때는 새 소비자가 `body_offset` 만 읽고
    /// `body_is_array` 를 잊어도 **컴파일이 통과한다** — 그리고 Codex 결과에서 조용히 빈 본문을
    /// 낸다. 묶어 두면 `body.` 를 치는 순간 둘이 함께 보이고, 이름이 바뀌었으므로 **기존 소비자
    /// 전부가 한 번은 이 자리를 지나게** 된다.
    body: ResultBody = .{},
};

/// 같은 메시지(= 같은 줄)에 붙은 여러 장 중 **몇 번째**인가(§2.2).
///
/// **왜 필요한가**: 라벨은 그 줄의 사용자 텍스트에서 나오므로, 한 메시지에 붙인 N 장이 **글자 그대로
/// 같은 라벨**을 받는다. 실측(2026-09-05, 이 맥의 Claude 트랜스크립트 131 파일)이 그것을 못 박았다 —
/// 사용자 첨부 199 장 중 27 장(13 줄)이 다중 첨부였고, 그 **13 줄 전부** 텍스트 블록이 하나뿐이며
/// 위치도 첫 이미지보다 앞(136~188 B)이라 **예외 없이 N 장이 같은 문장을 받는다**. 순번이 없으면
/// 격자에 같은 줄이 N 개 뜨고 어느 것이 몇 번째인지 알 길이 없다.
///
/// 시각으로도 못 가른다 — 같은 레코드라 타임스탬프까지 같다.
pub const Seq = struct {
    /// 1-based. **0 이면 그리지 않는다** — 한 장뿐이거나(=「1/1」은 알려 주는 것이 없다) 묶음이
    /// 상한을 넘었다는 뜻이다.
    index: u16 = 0,
    total: u16 = 0,
};

/// 한 묶음을 넓힐 상한. 실측 최대는 3 장이다(2026-09-05). 이것은 성능 방어다 — 넘으면 `Seq{}` 를
/// 돌려준다. 「2/500」은 알려 주는 것이 없고, 그것을 세느라 O(n²) 를 치를 이유는 더 없다.
pub const max_seq_group: usize = 64;

/// `hits[i]` 의 순번. **`hits` 는 스캐너가 담은 그대로여야 한다**(같은 줄의 이미지가 연속이라는 것이
/// 이 함수의 유일한 가정이다). 걸러 낸 목록에 쓰면 묶음이 쪼개져 「1/1」이 되므로, 부르는 자리는
/// 전체 목록 하나뿐이다.
///
/// **배열 방향에 기대지 않는다.** 갤러리는 최신을 먼저 보이려고 전체를 뒤집는데(`std.mem.reverse`),
/// 순번은 **적힌 순서**여야 한다. 그래서 이웃과의 위치가 아니라 `data_offset` 의 크기로 센다.
pub fn sequenceAt(hits: []const Hit, i: usize) Seq {
    if (i >= hits.len) return .{};
    const me = hits[i];

    var start = i;
    while (start > 0 and sameRecord(hits[start - 1], me)) {
        start -= 1;
        if (i - start >= max_seq_group) return .{};
    }
    var end = i + 1; // exclusive
    while (end < hits.len and sameRecord(hits[end], me)) {
        end += 1;
        if (end - start > max_seq_group) return .{};
    }

    const total = end - start;
    if (total < 2) return .{}; // 한 장뿐이면 순번은 소음이다
    var rank: u16 = 1;
    for (hits[start..end]) |h| {
        if (h.data_offset < me.data_offset) rank += 1;
    }
    return .{ .index = rank, .total = @intCast(total) };
}

/// 같은 레코드(= 같은 파일의 같은 줄)인가. 줄이 곧 메시지 하나다.
fn sameRecord(a: Hit, b: Hit) bool {
    return a.file_index == b.file_index and a.line_offset == b.line_offset;
}

/// 활성 pane 이 읽을 트랜스크립트 **묶음**. 재개 세션이면 부모까지다(§3.3).
///
/// **상한이 3인 근거는 실측이다**(2026-08-30): 체인 깊이가 중앙 1, 최대 2 였다. 하나를 더 두어
/// 최대를 넘겨도 잘리지 않게 한다. 무한히 따라가면 1.8 GB 짜리 부모가 줄줄이 붙는다.
pub const max_chain: usize = 3;

pub const Chain = struct {
    files: [max_chain]Source = [_]Source{.{}} ** max_chain,
    len: usize = 0,

    pub fn get(self: *const Chain, i: usize) ?[]const u8 {
        if (i >= self.len) return null;
        const p = self.files[i].path();
        return if (p.len == 0) null else p;
    }

    /// 뒤에 잇는다. 이미 있는 경로면 **더하지 않는다** — 부모가 자기 자신을 가리키는 기록이 오면
    /// 같은 파일을 두 번 훑고 이미지가 두 배로 뜬다.
    pub fn append(self: *Chain, value: []const u8) bool {
        if (self.len >= max_chain) return false;
        for (0..self.len) |i| {
            if (std.mem.eql(u8, self.files[i].path(), value)) return false;
        }
        if (!self.files[self.len].set(value)) return false;
        self.len += 1;
        return true;
    }

    pub fn clear(self: *Chain) void {
        for (&self.files) |*f| f.clear();
        self.len = 0;
    }

    pub fn isEmpty(self: *const Chain) bool {
        return self.len == 0;
    }

    /// 첫 파일(= 현재 세션). 갤러리가 「소스가 갈렸나」를 판정하는 기준이다.
    pub fn head(self: *const Chain) []const u8 {
        return if (self.len == 0) "" else self.files[0].path();
    }
};

/// 이 Term 이 읽을 트랜스크립트의 **절대 경로**. 훅 `SessionStart`/`UserPromptSubmit` 이 `transcript_path` 로
/// 통째로 주므로(계약 §4.4) 디렉터리를 조립하거나 추측하지 않는다.
///
/// 힙을 잡지 않는 고정 버퍼다 — `agent_transcript.Cache` 와 같은 규율이라 Term 파괴가 따로 해제하지 않는다.
///
/// **512인 근거(2026-08-29 실측)**: 이 기계의 트랜스크립트 경로 4,155개에서 최대 **215자**, p99 205자였고
/// 256자를 넘는 것이 하나도 없었다. 길이는 사실상 cwd 가 정하는데(claude 는 cwd 를 인코딩한 디렉터리 이름을
/// 쓴다), 512면 cwd 400자까지 담는다. **넘치면 담지 않는다 — 자르지 않는다**: 자른 경로는 없는 파일이거나,
/// 더 나쁘게는 **다른 파일**을 가리킨다.
pub const max_source_path_bytes: usize = 512;

/// 갤러리가 읽는 대상 하나.
pub const Source = struct {
    buf: [max_source_path_bytes]u8 = undefined,
    len: usize = 0,

    pub fn path(self: *const Source) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const Source) bool {
        return self.len == 0;
    }

    /// 경로를 바꾼다. 바뀌었으면 true — 호출자가 그때만 인덱스를 버린다.
    /// 상한을 넘거나 절대 경로가 아니면 **비운다**(추측한 경로로 남의 파일을 읽지 않는다).
    pub fn set(self: *Source, value: []const u8) bool {
        if (value.len == 0 or value.len > max_source_path_bytes or value[0] != '/') {
            const had = self.len != 0;
            self.len = 0;
            return had;
        }
        if (self.len == value.len and std.mem.eql(u8, self.buf[0..self.len], value)) return false;
        @memcpy(self.buf[0..value.len], value);
        self.len = value.len;
        return true;
    }

    pub fn clear(self: *Source) void {
        self.len = 0;
    }
};

const claude_image_marker = "\"type\":\"image\",\"source\":{\"type\":\"base64\"";
const claude_tool_file_marker = "\"file\":{\"base64\":\"";
const codex_marker = "\"type\":\"input_image\"";
const compacted_marker = "\"type\":\"compacted\"";
const claude_tool_use_marker = "\"type\":\"tool_use\"";
const codex_custom_tool_call_marker = "\"type\":\"custom_tool_call\"";
const codex_function_call_marker = "\"type\":\"function_call\"";

const name_key = "\"name\":\"";
/// 결과 레코드의 마커(AV2). **호출 마커와 안 겹친다** — 닫는 따옴표까지 들으므로
/// `"custom_tool_call"` 이 `"custom_tool_call_output"` 에 안 걸리는 것과 같은 규율이다.
const claude_tool_result_marker = "\"type\":\"tool_result\"";
const codex_custom_output_marker = "\"type\":\"custom_tool_call_output\"";
const codex_function_output_marker = "\"type\":\"function_call_output\"";

/// 결과 마커를 찾을 **창**. 줄 머리에서 이만큼만 본다.
///
/// ⚠️ **실측이 이 창을 강제했다**(2026-09-07, 3.2 GB Codex rollout). 결과 마커를 **줄 전수**로 훑는
/// 판은 5.1 초 → 7.4 초로 **+2.3 초(+46%)** 였다. 마커 탐색은 줄마다 전 바이트를 지나므로 그 자체가
/// 스캔 비용이고, 이 파일은 줄 하나가 평균 5 KB 다.
///
/// **창은 실측으로 정했다**: Claude `"type":"tool_result"` 는 중앙 221 · **최대 250**, Codex 출력
/// 마커는 중앙 74 · p99.9 90 이다. 512 B 는 Claude 최대의 2 배다.
///
/// **창 밖이면 못 잡는다 — 그 대가를 실제로 셌다**: 코퍼스 225,004 건 중 창 밖은 **132 건(0.07%)**
/// 이고 **그 132 건이 전부 `compacted` 줄**이다(이전 대화 재수록 — 위에서 통째로 건너뛴다). 즉 이
/// 창이 실제로 잃는 것은 **0 건**이다. 못 잡으면 그 호출은 요약 없이 남는다(틀린 값을 적지 않는다).
const result_search_window: usize = 512;

/// 호출 id 의 키. Claude 는 호출 레코드 안의 `"id"`, Codex 는 `"call_id"` 다.
///
/// ⚠️ `"id\":\"` 는 **여는 따옴표를 포함**하므로 `"tool_use_id":"` 에는 걸리지 않는다(그 앞 글자가 `_`
/// 다). 그 성질이 없으면 결과 레코드의 id 를 호출 id 로 잘못 집는다.
const id_key = "\"id\":\"";
const call_id_key = "\"call_id\":\"";
const tool_use_id_key = "\"tool_use_id\":\"";
/// 결과 본문의 키. **따옴표를 안 붙인다** — 값이 문자열(`"…"`)일 수도 배열(`[…]`)일 수도 있어서
/// 한 번 찾고 **다음 한 바이트**로 갈래를 정한다. 실측: Codex 출력 184,202 건 중 135,085 건이 배열이다.
const content_key_base = "\"content\":";
const output_key_base = "\"output\":";
const text_key = "\"text\":\"";
/// Claude 가 **자기가** 적는 실패 표시. 우리가 판정하지 않는다는 계약(§2.3)의 근거다.
const is_error_true = "\"is_error\":true";

/// 시각 키. 값 파싱은 `agent_image_context.timestampSeconds` 가 소유한다 — 여기서는 **자리만** 찾는다.
const timestamp_key = "\"timestamp\":\"";

/// 시각을 찾을 창 — **provider 마다 반대편이라 따로 잰다**(2026-09-07 실측, 이 맥의 최근 세션).
///
/// | | 있는 비율 | 자리 |
/// |---|---|---|
/// | Claude 호출 | 100%(40,676/40,676) | **마커 뒤**. 중앙 1,454 · p99 7,228 · 최대 38,753 |
/// | Codex 호출 | 100%(185,033/185,033) | **줄 머리**. 중앙·p99·최대 모두 **1** |
///
/// ⚠️ 이 비대칭이 AV1-b 가 시각을 미룬 이유다 — 이미지 경로(payload 뒤 256 B, 앞 16 KB)를 그대로
/// 쓰면 Claude 는 명령 뒤 한참 뒤에 있는 값을 못 보고, 잘못하면 **다음 레코드의 시각**을 집는다.
/// 한 줄에 레코드가 하나라(계약 §3.1) 마커 뒤 첫 값이 곧 이 레코드의 것이고, 실측으로 그 줄에
/// `"timestamp":"` 가 둘 이상인 경우는 **0 건**이다.
const claude_time_window: usize = 64 * 1024;
const codex_time_window: usize = 256;
/// 대상 문자열의 자리를 정하는 키들. **순서가 계약이다**(계약 §2.2) — 앞의 것이 있으면 그것을 쓴다.
const description_key = "\"description\":\"";
const file_path_key = "\"file_path\":\"";
const command_key = "\"command\":\"";
const input_key = "\"input\":\"";
const arguments_key = "\"arguments\":\"";

/// 대상 문자열의 끝을 찾을 때 훑는 최대 바이트. 라벨 상한(160 B)의 3.2 배다 — 라벨에 들어갈 몫과
/// 「이 자리가 어디서 시작하는가」만 알면 되고, 전문은 펼칠 때 파일에서 다시 읽는다.
const max_target_scan_bytes: usize = 512;

/// 안쪽 호출(`tools.X(...)`)의 인자를 훑는 최대 바이트. **바깥보다 넉넉해야 한다** — 껍데기
/// (`text(await tools.exec_command({cmd:`)가 앞에서 자리를 먹고, 값 자체도 여러 줄 명령이면 길다.
///
/// **실측이 값을 정했다**(2026-09-10): 이 값이 512 B 였을 때 실제 세션에서 **17 줄 중 2 줄**이
/// 값의 닫는 따옴표를 못 봐 폴백했다(`node --input-type=module <<'JS' …`). 4 KiB 면 그 줄들이 덮이고,
/// 라벨은 어차피 160 B 라 더 늘려도 화면이 달라지지 않는다.
const max_inner_scan_bytes: usize = 4096;

/// 한 줄에서 **인자까지 뜯어 보는** `tools.…(` 후보의 최대 개수.
///
/// ⚠️ **이 못이 없으면 한 줄이 O(후보 × 창)** 이 된다. 후보마다 `firstArgString` 이 창 끝까지 갈 수
/// 있으므로 4 KiB 창에 `tools.a(` 를 꽉 채우면 후보가 512 개까지 나오고, 한 줄에 2 MB 를 훑는다.
/// 실측(2026-09-10): 그런 줄로만 채운 65 MB 문서가 **483 → 9 MB/s (53배)** 로 무너졌다.
///
/// 16 인 이유: 실측 186,135 개 입력에서 후보는 **최대 8 개**였고(9 개 이상 0.000%), 대상을 주는 첫
/// 후보는 99.99% 가 **0 번째**였다. 관측 최대의 두 배를 두면 실데이터는 한 건도 안 잘린다.
const max_inner_calls: usize = 16;

const data_key = "\"data\":\"";
const image_url_key = "\"image_url\":\"";
const media_type_key = "\"media_type\":\"";

/// 마커 뒤에서 키를 찾을 때 훑는 최대 바이트. 레코드 머리는 짧고(실측 수십 바이트) payload는 그 뒤에 오므로,
/// 이 창을 넘어가면 그것은 **다른 레코드의 키**다 — 무한정 앞을 보면 엉뚱한 이미지를 짝지어 준다.
const key_search_window: usize = 512;

/// 한 줄을 훑어 이미지 자리를 `out`에 덧붙인다. `line_offset`은 그 줄의 파일 절대 시작이다.
///
/// **Codex `compacted`는 통째로 건너뛴다**(§3.3). 그 레코드는 이전 대화를 이미지째 재수록하므로,
/// 세지 않으면 실측처럼 15,140개 대 실제 151개가 된다. 원본이 같은 파일 앞쪽에 이미 있어 잃는 것이 없다.
pub fn scanLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    if (line.len == 0 or line.len > max_line_bytes) return;
    // **가장 먼저, 그리고 줄 앞부분만 본다.** 여기서 되돌아가면 아래 세 패스를 통째로 건너뛴다 —
    // 실측 파일에서 compacted 줄이 **바이트의 41%(812 MB / 871 줄)** 라 그 절약이 크다.
    if (isCompacted(line)) return;

    const before = out.items.len;
    try scanClaudeImages(allocator, line, line_offset, out);
    const after_images = out.items.len;
    try scanClaudeToolFiles(allocator, line, line_offset, out);
    dropToolFileDuplicates(out, before, after_images);
    try scanCodexImages(allocator, line, line_offset, out);
    // 활동은 이미지와 **같은 줄에 공존하지 않는다**(호출 레코드와 결과 레코드가 다른 줄이다). 그래도
    // 순서를 뒤에 두는 이유는 위 세 패스가 `dropToolFileDuplicates` 로 **자기들끼리 접기** 때문이다 —
    // 사이에 끼면 그 접기가 남의 항목을 셈에 넣는다.
    try scanClaudeToolUses(allocator, line, line_offset, out);
    try scanCodexToolCalls(allocator, line, line_offset, out);
}

/// `compacted` 레코드인가. **줄 앞부분만** 본다.
///
/// 예전에는 줄 전체를 훑었는데, 실측(1,981 MB rollout)에서 그 한 패스가 **2,817 ms · 전체의 28%**
/// 였다. 그런데 이 마커는 JSON 구조상 **줄 머리에 고정**이다 — 실측 296 파일 / **14,206 줄**에서
/// 위치가 중앙 40, **최대 55** 였다. 창을 그 74 배로 잡아도 O(1) 이다.
///
/// **창 밖에 있으면 못 잡는다**: 그 줄의 이미지가 갤러리에 다시 뜬다(compacted 는 이전 대화를
/// 이미지째 재수록하므로 실측 15,140 개 대 실제 151 개가 된다). 창을 넉넉히 두는 이유가 그것이다.
fn isCompacted(line: []const u8) bool {
    const window = line[0..@min(line.len, compacted_search_window)];
    return std.mem.indexOf(u8, window, compacted_marker) != null;
}

/// `compacted` 마커를 찾을 창(바이트). 실측 최대 55 의 **9.3 배**다.
///
/// **더 넓히면 그만큼 느려진다**: 줄마다 이 창을 훑고 이 파일에는 줄이 649,381 개라, 4 KiB 로 두면
/// 누적 1.9 GB 를 훑어 **2.0 초**가 된다(실측). 512 B 면 332 MB 라 0.4 초다. 마커가 구조상 줄 머리에
/// 고정(중앙 40 · 최대 55)이므로 이 여유로 충분하다.
const compacted_search_window: usize = 512;

/// **같은 이미지의 두 번째 사본을 접는다**(§4.3). 접지 않으면 에이전트가 읽은 이미지가 갤러리에
/// 두 번씩 뜬다 — 실측 3,226 장 중 1,424 장(44%)이 이 사본이었다.
///
/// 접는 기준은 **같은 줄에 `claude_image` 가 있는가** 하나다. 왜 그것으로 충분한지는 실측이 말한다
/// (2026-08-29, 실제 트랜스크립트 2,548 파일):
///
/// | 잰 것 | 값 | 뜻 |
/// | --- | --- | --- |
/// | `tool_file` 만 있는 줄 | **0** | 접어도 잃는 것이 없다 |
/// | 개수 불일치 줄 | **0** | 언제나 1:1 이다 |
/// | payload 가 다른 줄 | **0** | base64 바이트가 글자 그대로 같다 |
///
/// **그래도 「같은 줄에 있으면」 조건을 남긴다.** 무조건 버리면 provider 가 언젠가 `toolUseResult` 만
/// 쓰는 레코드를 내보낼 때 그 이미지가 통째로 사라지고, 증상은 「어떤 이미지는 안 보인다」라 원인을
/// 찾기 어렵다. 조건을 두면 그 경우 사본이 아니라 **유일본**이므로 그대로 남는다.
fn dropToolFileDuplicates(out: *std.ArrayList(Hit), line_start: usize, images_end: usize) void {
    if (images_end == line_start) return; // 이 줄에 `claude_image` 가 없다 = 사본이 아니라 유일본
    if (out.items.len == images_end) return; // 접을 것이 없다
    out.shrinkRetainingCapacity(images_end);
}

fn scanClaudeImages(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, claude_image_marker)) |m| {
        i = m + claude_image_marker.len;
        const span = findQuotedValue(line, i, data_key) orelse continue;
        const mime = blk: {
            const mt = findQuotedValue(line, i, media_type_key) orelse break :blk Mime.unknown;
            // media_type 은 data 보다 **앞**에 와야 이 레코드의 것이다. 뒤에 있으면 다음 레코드의 값이다.
            if (mt.start > span.start) break :blk Mime.unknown;
            break :blk Mime.parse(line[mt.start .. mt.start + mt.len]);
        };
        try append(allocator, out, line_offset, span, .claude_image, mime);
        i = span.start + span.len;
    }
}

fn scanClaudeToolFiles(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, claude_tool_file_marker)) |m| {
        const start = m + claude_tool_file_marker.len;
        const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse {
            i = start;
            continue;
        };
        try append(allocator, out, line_offset, .{ .start = start, .len = end - start }, .claude_tool_file, .unknown);
        i = end;
    }
}

fn scanCodexImages(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, codex_marker)) |m| {
        i = m + codex_marker.len;
        const url = findQuotedValue(line, i, image_url_key) orelse continue;
        // `data:<mime>;base64,` 접두를 벗긴다. 그 모양이 아니면 인덱싱하지 않는다 — 원격 URL 이미지는
        // 바이트가 파일에 없으므로 갤러리가 보여 줄 수 있는 것이 아니다.
        const value = line[url.start .. url.start + url.len];
        if (!std.mem.startsWith(u8, value, "data:")) {
            i = url.start + url.len;
            continue;
        }
        const comma = std.mem.indexOfScalar(u8, value, ',') orelse {
            i = url.start + url.len;
            continue;
        };
        const header = value[5..comma]; // "data:" 다음부터 `,` 앞까지 = `<mime>;base64`
        const semi = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
        const mime = Mime.parse(header[0..semi]);
        const payload_start = url.start + comma + 1;
        try append(allocator, out, line_offset, .{
            .start = payload_start,
            .len = url.start + url.len - payload_start,
        }, .codex_input_image, mime);
        i = url.start + url.len;
    }
}

/// Claude 의 도구 호출 한 건을 잡는다.
///
/// **한 줄에 하나다**(실측 39,618 / 39,618 — 계약 §3.1). 병렬 호출도 provider 가 레코드를 나눠 쓰므로
/// 반복 루프가 필요 없고, 그래서 키를 **줄 전체**에서 찾아도 남의 레코드 값을 집을 수 없다. 이미지
/// 패스가 `key_search_window` 로 창을 좁히는 것과 갈리는 지점이고, 그 차이가 여기서는 필수다 —
/// `description` 은 23 KB 짜리 `command` 뒤에 올 수 있어 512 바이트 창이면 못 본다.
fn scanClaudeToolUses(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, claude_tool_use_marker)) |m| {
        const after = m + claude_tool_use_marker.len;
        // **자기 레코드 안에서만 값을 찾는다.** 실측은 「한 줄에 하나」였지만(39,618 / 39,618) 코드가
        // 그 전제에 **의존하면** provider 가 포맷을 바꾸는 날 조용히 틀린다 — 적대적 검증에서 실제로
        // 첫 호출의 라벨로 **두 번째 호출의 경로**가 나왔다. 다음 마커 앞까지로 범위를 닫으면 전제가
        // 깨져도 각자 제 값을 갖는다(전제가 참인 동안 비용은 그대로다).
        const end = std.mem.indexOfPos(u8, line, after, claude_tool_use_marker) orelse line.len;
        const scope = line[0..end];
        i = end;

        const name = findQuotedValue(scope, after, name_key) orelse continue;
        const activity = Activity.fromToolName(scope[name.start .. name.start + name.len]);
        // 대상이 없으면 **이름이 대상이다** — 「무엇을 했는지」를 못 적느니 도구 이름이라도 적는다.
        const picked = pickClaudeTargetKeyed(scope, after);
        const target = picked.span orelse name;
        // **펼침은 명령을 보여 준다**(계약 §2.2 ⚠️). 대상이 이미 명령이면 다시 안 찾는다.
        const cmd_rel: u32 = if (picked.is_command)
            0
        else if (findEscapedValue(scope, after, command_key)) |c|
            (if (c.start <= std.math.maxInt(u32)) @intCast(c.start) else 0)
        else
            0;
        // **자기 레코드 범위 안에서** id 를 찾는다(위 `scope` 와 같은 이유 — 한 줄에 호출이 둘이면
        // 줄 전체에서 찾은 id 는 남의 것일 수 있다).
        const id = findQuotedValueFull(scope, after, id_key);
        // Claude 의 시각은 **마커 뒤**다(실측 40,676/40,676 · 중앙 1,454 · 최대 38,753).
        const time_rel = timestampKeyRel(scope, after, claude_time_window);
        try appendActivity(allocator, out, line_offset, target, name, .claude_tool_use, activity, id, time_rel, cmd_rel);
        if (end == line.len) break;
    }
}

/// Codex 의 도구 호출 한 건. `custom_tool_call` 과 `function_call` 두 모양을 다 본다.
///
/// **결과 레코드와 헷갈리지 않는다**: 마커가 닫는 따옴표까지 포함하므로 `"custom_tool_call_output"`
/// 에는 걸리지 않는다.
fn scanCodexToolCalls(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    const m = std.mem.indexOf(u8, line, codex_custom_tool_call_marker) orelse
        std.mem.indexOf(u8, line, codex_function_call_marker) orelse return;
    const after = m;
    // Claude 쪽과 같은 이유로 범위를 닫는다 — 뒤에 또 호출이 있으면 그 값은 그쪽 것이다.
    const next = std.mem.indexOfPos(u8, line, after + 1, codex_custom_tool_call_marker) orelse
        std.mem.indexOfPos(u8, line, after + 1, codex_function_call_marker) orelse line.len;
    const scope = line[0..next];
    const outer_name = findQuotedValue(scope, after, name_key) orelse return;
    const outer_target = pickCodexTarget(scope, after);
    // **껍데기를 벗긴다**(`pickCodexInnerCall` 의 근거). 못 벗기면 옛 동작 그대로다 —
    // 4~6 월 세션(실측 35,126 건)은 애초에 이 모양이 아니고, 그때는 폴백이 정답이다.
    // ⚠️ **여기서는 `outer_target` 의 끝을 창으로 쓰면 안 된다.** 그 끝은 `max_target_scan_bytes`
    // (512 B)에 잘린 자리다 — 라벨에 들어갈 몫만 알면 되기 때문이다(§4.2). 그런데 안쪽 인자는 그보다
    // 길 때가 많아(실측: `node --input-type=module <<'JS' …` 같은 여러 줄 명령), 잘린 창 안에서는
    // **값의 닫는 따옴표를 못 봐** 통째로 폴백했다. 실제 화면에서 절반만 벗겨진 것이 그 자국이다.
    //
    // 안쪽 명령도 **라벨에 들어갈 몫**만 있으면 되므로 창을 그만큼 따로 연다.
    const inner_limit = @min(scope.len, (if (outer_target) |t| t.start else 0) + max_inner_scan_bytes);
    const inner = if (outer_target) |t| pickCodexInnerCall(scope, t.start, inner_limit) else null;
    const name = if (inner) |v| v.name else outer_name;
    // **갈래도 안쪽 이름이 정한다.** 바깥 `exec` 는 JS 샌드박스라는 **껍데기**일 뿐이라, 그것으로
    // 가르면 파일을 고치는 `apply_patch` 와 계획을 적는 `update_plan` 이 「명령」에 들어앉고
    // (실측 27,168 건) 그림을 여는 `view_image` 226 건은 「읽기」에 못 간다.
    //
    // ⚠️ **표를 먼저 넓히지 않고 이 줄만 바꾸면 「명령」이 무너진다** — 앞선 슬라이스가 실측으로
    // 확인했다(171,379 → 106 · 74.6% 가 「그 밖」으로). 순서가 곧 결함이므로 둘을 한 커밋에 둔다.
    //
    // 모르는 안쪽 이름은 **바깥으로 안 돌아간다**. 바깥은 언제나 `exec` 이므로 돌아가면 모르는
    // 도구가 전부 「명령」이 된다 — `mcp__codex_apps__github_*` 이 명령일 리 없다. 껍데기를 벗긴
    // 이상 안쪽 이름이 그 호출의 **진짜 이름**이고, 모르면 `other` 가 정확한 답이다(§2.3).
    const activity = Activity.fromToolName(scope[name.start .. name.start + name.len]);
    const target = blk: {
        if (inner) |v| {
            // ⚠️ **빈 대상은 줄을 통째로 없앤다** — `appendActivity` 가 `target.len == 0` 이면 담지
            // 않는다. `write_stdin` 의 `chars` 는 실측상 빈 값일 때가 많아(Enter 만 보내는 것이다)
            // 그대로 쓰면 **55,416 건이 목록에서 사라진다**. 그때는 껍데기라도 보이는 편이 낫다.
            if (v.target) |tt| {
                if (tt.len > 0) break :blk tt;
            }
        }
        break :blk outer_target orelse name;
    };
    // Codex 의 `call_id` 는 `type` **앞에** 올 수 있어 범위의 처음부터 찾는다(범위는 위에서 닫았다).
    const id = findQuotedValueFull(scope, 0, call_id_key);
    // Codex 의 시각은 **줄 머리**다(실측 자리 중앙·p99·최대 모두 1) — 마커 뒤에서 찾으면 못 본다.
    const time_rel = timestampKeyRel(scope, 0, codex_time_window);
    // **대상이 곧 명령이다** — Codex 는 사람이 읽는 설명 필드가 없다(§2.2). 안쪽 호출을 벗겼으면
    // 그 인자의 첫 문자열 값이 곧 명령이고, 못 벗겼으면 `input` 전체가 그것을 대신한다.
    try appendActivity(allocator, out, line_offset, target, name, .codex_tool_call, activity, id, time_rel, 0);
}

/// 화면에 적을 **대상**의 자리를 고른다. 순서가 계약이다(§2.2) — 실측이 정한 순서다:
/// `description` 은 Bash 의 68.8% 에 있고 중앙 26 B 라 라벨에 언제나 들어가는 반면, 명령 첫 줄은
/// **52.4% 가 여러 줄**이고 **27.4%** 가 라벨 상한을 넘는다.
fn pickClaudeTarget(line: []const u8, from: usize) ?Span {
    return pickClaudeTargetKeyed(line, from).span;
}

/// 위와 같되 **무엇이 골라졌는지**도 알려 준다. 펼침이 명령을 따로 찾아야 하는지 그 답으로 정한다 —
/// 이미 명령이 골라졌으면 같은 줄을 한 번 더 훑을 이유가 없다(AV2 가 배운 그 비용이다).
fn pickClaudeTargetKeyed(line: []const u8, from: usize) struct { span: ?Span, is_command: bool } {
    if (findEscapedValue(line, from, description_key)) |v| return .{ .span = v, .is_command = false };
    if (findEscapedValue(line, from, file_path_key)) |v| return .{ .span = v, .is_command = false };
    if (findEscapedValue(line, from, command_key)) |v| return .{ .span = v, .is_command = true };
    return .{ .span = null, .is_command = false };
}

/// Codex 호출 레코드에는 **사람이 읽는 설명 필드가 없다**(키 실측: `call_id,id,input,…,name,status,type`).
/// 그래서 언제나 명령 문자열이 대상이고, provider 사이에서 화면이 달라지는 것을 그대로 둔다(§2.2).
fn pickCodexTarget(line: []const u8, from: usize) ?Span {
    if (findEscapedValue(line, from, input_key)) |v| return v;
    if (findEscapedValue(line, from, arguments_key)) |v| return v;
    return null;
}

/// Codex 의 `exec` 는 **셸이 아니라 JavaScript 를 받는다**(2026-07 부터). 모델이 그 안에서
/// `tools.<이름>({...})` 을 부르므로, provider 가 준 이름과 `input` 첫 줄은 **껍데기**다.
///
/// **실측이 이 규칙을 요구했다**(2026-09-10, 이 맥의 Codex 세션 229,634 호출):
///
/// | | 값 |
/// | --- | ---: |
/// | `tools.X(` 모양 | **74.6%**(2026-09 만 보면 **93.7%**) |
/// | 화면의 이름 칸이 `exec` 하나 | **74.4%** |
/// | JS 껍데기가 먹는 라벨 | 평균 **34.5 B**(상한 160 B 의 22%) |
///
/// 안쪽 이름은 `exec_command` 91,431 · `write_stdin` 55,416 · `apply_patch` 21,874 로 갈린다 —
/// 「무엇을 돌렸나」가 이름 칸에서 비로소 답이 된다.
///
/// ⚠️ **형식이 두 달 만에 뒤집혔다.** 2026-06 까지 이 모양은 **0%** 였다. 그래서 이 규칙은 **언제나
/// 물러날 자리를 갖는다** — 못 찾으면 옛 동작 그대로다(4~6월 세션 35,126 건이 지금도 그 길로 간다).
///
/// **베이스**(§11): 공개 뷰어 [codex-trace](https://github.com/PixelPaw-Labs/codex-trace)(MIT)·
/// [codex-transcript-viewer](https://github.com/masonc15/codex-transcript-viewer)(MIT)를 확인했고
/// **둘 다 안쪽 이름을 안 꺼낸다**(바깥 `name` 과 raw input 을 그대로 쓴다). 전문을 펼쳐 보이는 화면은
/// 껍데기가 문제되지 않기 때문이다 — **한 줄 목록이라는 이 뷰의 제약에서만** 필요한 규칙이라 직접 세웠다.
/// 코드 표현은 옮기지 않았고, 규칙은 위 실측이 정했다.
const InnerCall = struct {
    /// 안쪽 도구 이름(`exec_command` 등)의 자리.
    name: Span,
    /// 화면에 적을 대상 — 인자의 **첫 문자열 값**. 못 고르면 `null`(폴백).
    target: ?Span,
};

/// `tools.<이름>(` 를 찾아 안쪽 이름과 대상을 고른다.
///
/// **이스케이프된 원문 위에서 돈다.** 스캐너가 보는 것은 파일 바이트이므로 JS 의 `"` 는 `\"` 다 —
/// 푸는 것은 라벨 층의 일이고(§4.2 「스캐너는 자리만 든다」), 여기서는 그 모양 그대로 센다.
fn pickCodexInnerCall(line: []const u8, from: usize, limit: usize) ?InnerCall {
    var examined: usize = 0;
    return pickCodexInnerCallCounting(line, from, limit, &examined);
}

/// `pickCodexInnerCall` 과 같되 **인자를 뜯어 본 후보 수**를 돌려준다.
///
/// 이 수가 곧 한 줄의 일감 상한이다(`examined × 창`). 판정자가 시계 대신 이 수를 보므로 느린 CI
/// 에서도 흔들리지 않는다 — 시계로 재면 「53배 느려짐」을 잡으려다 간헐 실패를 만든다.
fn pickCodexInnerCallCounting(line: []const u8, from: usize, limit: usize, examined_out: *usize) ?InnerCall {
    var i = from;
    var first: ?InnerCall = null;
    var examined: usize = 0;
    defer examined_out.* = examined;
    while (std.mem.indexOfPos(u8, line, i, tools_prefix)) |t| {
        if (t >= limit) break;
        if (examined >= max_inner_calls) break;
        const ns = t + tools_prefix.len;
        var ne = ns;
        while (ne < limit and isIdentByte(line[ne])) ne += 1;
        i = t + tools_prefix.len;
        if (ne == ns or ne >= limit or line[ne] != '(') continue;
        // **인자를 뜯는 것만 센다.** `tools.` 라는 말만 있고 호출이 아닌 자리는 공짜다.
        examined += 1;
        var exhausted = false;
        const call: InnerCall = .{
            .name = .{ .start = ns, .len = ne - ns },
            .target = firstArgString(line, ne, limit, &exhausted),
        };
        // **이름과 대상은 같은 호출에서 나와야 한다.** 한 스크립트가 여러 도구를 부를 수 있는데
        // (실측: `tools.get_goal({})` 다음에 `tools.exec_command({...})`), 첫 호출의 인자가 비었다고
        // 그 자리에 **뒤 호출의 값**을 쓰면 이름과 대상이 다른 일을 가리킨다.
        //
        // 그래서 **대상까지 있는 첫 호출**을 고른다. 하나도 없으면 첫 호출의 이름만 쓰고 대상은
        // 폴백이다 — 이름은 여전히 `exec` 보다 낫다.
        if (call.target != null) return call;
        if (first == null) first = call;
        // 이 후보가 창을 다 쓰도록 값을 못 봤다 = 뒤 후보도 못 본다(같은 바이트의 뒷부분이다).
        if (exhausted) break;
    }
    return first;
}

fn isIdentByte(c: u8) bool {
    return c == '_' or (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// 여는 괄호(`open`)부터 **짝이 맞는 닫는 괄호**까지가 인자다. 그 **안에서만** 첫 문자열 값을 고른다.
///
/// ⚠️ **범위를 안 지키면 남의 값을 집는다**(적대적 검증). `tools.get_goal({})` 처럼 인자가 비면
/// 뒤에 이어지는 **다른 호출**의 값을 집었고, `{cmd, workdir:"…"}` 처럼 첫 키가 **축약 프로퍼티**면
/// 그 다음 키(`workdir`)를 집어 줄마다 같은 디렉터리가 떴다. 둘 다 **폴백이 정직한** 자리다.
///
/// 「첫 문자열 값」이 맞는 근거도 실측이다 — 대표 필드를 실제로 뽑을 수 있던 147,581 건에서
/// **99.99%** 가 일치했다. 빈 문자열을 건너뛰면 오히려 **63.5%** 로 떨어진다(`write_stdin` 의
/// `chars` 는 정말 빈 값일 때가 많다 — Enter 만 보내는 것이다).
///
/// 못 찾았을 때는 **왜 못 찾았는지**를 `exhausted` 로 알린다.
///
/// `exhausted = true` 는 「창(`limit`)을 다 쓰도록 값이 없었다」다. 이 신호가 중요한 이유는
/// 뒤 후보들이 **같은 바이트의 뒷부분**만 보기 때문이다 — 앞 후보가 창 끝까지 훑고도 못 찾았으면
/// 뒤 후보도 못 찾는다. 그래서 `pickCodexInnerCall` 이 거기서 멈출 수 있고, 한 줄이
/// O(후보 × 창) 에서 O(창) 으로 내려온다(실측 9 → 483 MB/s).
///
/// 반대로 `exhausted = false` 는 구조를 보고 일찍 되돌아온 것이다(인자가 닫혔다·축약 프로퍼티).
/// 그때는 뒤 후보가 아직 값을 줄 수 있으므로 멈추면 안 된다.
fn firstArgString(line: []const u8, open: usize, limit: usize, exhausted: *bool) ?Span {
    exhausted.* = false;
    var depth: usize = 0;
    var i = open;
    // **키와 값을 가른다.** `:` 를 본 뒤의 문자열만 값이다 — 안 가르면 `{"session_id":1,"chars":""}`
    // 에서 키 `chars` 를 값으로 집는다(판정자가 그것을 잡았다).
    var seen_colon = false;
    // 첫 프로퍼티를 지났나. **축약은 첫 키에서만** 폴백 사유다(실측이 그 자리만 봤다).
    var passed_first = false;
    while (i < limit) : (i += 1) {
        const c = line[i];
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return null; // 인자가 끝났다 — 문자열 값이 없었다
            },
            ':' => seen_colon = true,
            ',' => {
                // 첫 키가 `:` 없이 끝났다 = **축약 프로퍼티**. 값이 이 줄에 없다(실측 537 건).
                if (!seen_colon and !passed_first) return null;
                passed_first = true;
                seen_colon = false; // 다음은 다시 키다
            },
            '\\' => {
                // 파일 바이트에서 JS 문자열의 따옴표는 `\"` 다.
                if (i + 1 < limit and line[i + 1] == '"') {
                    if (!seen_colon) {
                        // 키 쪽 문자열 — 통째로 건너뛴다(그 안의 `:`·`,` 를 구조로 오해하지 않게).
                        var k = i + 2;
                        while (k + 1 < limit) : (k += 1) {
                            if (line[k] != '\\') continue;
                            if (line[k + 1] == '"') break;
                            k += 1;
                        }
                        if (k + 1 >= limit) {
                            exhausted.* = true;
                            return null;
                        }
                        i = k + 1;
                        continue;
                    }
                    const vs = i + 2;
                    var j = vs;
                    while (j + 1 < limit) : (j += 1) {
                        if (line[j] != '\\') continue;
                        // `\"` 가 값의 끝이다.
                        if (line[j + 1] == '"') return .{ .start = vs, .len = j - vs };
                        // 🔥 **이스케이프가 두 겹이다**(적대적 3회차 · 실측 1,625 건 = 활동 줄의 10.2%).
                        // 파일 바이트 `\\` 는 JSON 이 감싼 **JS 소스의 백슬래시 하나**이고, 그 백슬래시는
                        // 다시 **다음 JS 글자**를 감싼다. 그 다음 글자가 따옴표면 파일에는 `\"` 로 적히는데,
                        // 여기서 안 건너뛰면 그것을 **값의 끝**으로 읽는다 — `rg -n \\"post-callback…` 이
                        // 통째로 `rg -n \\` 로 잘렸다.
                        if (line[j + 1] == '\\') {
                            var k = j + 2; // JS 백슬래시를 지났다 — 이제 그것이 감싼 글자다
                            if (k < limit and line[k] == '\\') k += 2 else k += 1;
                            if (k - 1 >= limit) {
                                exhausted.* = true; // 창 밖으로 나갔다
                                return null;
                            }
                            j = k - 1; // 루프의 `j += 1` 이 `k` 로 만든다
                            continue;
                        }
                        j += 1;
                    }
                    exhausted.* = true;
                    return null;
                }
                i += 1; // 그 밖의 이스케이프는 통째로 건너뛴다
            },
            '\'' => {
                // JS 홑따옴표 문자열 — 파일 바이트에서 이스케이프가 없다.
                const vs = i + 1;
                var j = vs;
                while (j < limit) : (j += 1) {
                    if (line[j] == '\\') {
                        j += 1;
                        continue;
                    }
                    if (line[j] == '\'') break;
                }
                if (j >= limit) {
                    exhausted.* = true;
                    return null;
                }
                if (seen_colon) return .{ .start = vs, .len = j - vs };
                i = j;
            },
            else => {},
        }
    }
    exhausted.* = true;
    return null;
}

/// `tools.` — 안쪽 호출의 표지.
const tools_prefix = "tools.";

/// 이스케이프를 인지해 따옴표 값의 끝을 찾는다.
///
/// **base64 와 다른 점이 이것이다.** 이미지 payload 에는 이스케이프가 없어 다음 `"` 가 곧 끝이지만,
/// 사람이 쓴 명령에는 `\"` 와 `\n` 이 흔하다(명령의 52.4% 가 여러 줄이다). 그대로 `indexOfScalar`
/// 를 쓰면 명령 중간에서 잘려 **엉뚱한 자리**를 대상으로 잡는다.
fn findEscapedValue(line: []const u8, from: usize, key: []const u8) ?Span {
    const k = std.mem.indexOfPos(u8, line, from, key) orelse return null;
    const start = k + key.len;
    // **끝까지 훑지 않는다.** 이 자리는 라벨(160 B)에 들어갈 만큼만 알면 되고, 펼침은 파일에서 그
    // 자리부터 **다시** 읽는다(계약 §2.4). 명령은 최대 23 KB 라 끝을 찾자고 전부 훑으면 스캔이
    // 몇 배가 된다 — 실측으로 그 대가를 확인하고 상한을 뒀다.
    const limit = @min(line.len, start + max_target_scan_bytes);
    var i = start;
    while (i < limit) : (i += 1) {
        switch (line[i]) {
            // 이스케이프된 한 글자는 값의 일부다 — 그것이 `"` 여도 끝이 아니다.
            '\\' => i += 1,
            '"' => return .{ .start = start, .len = i - start },
            else => {},
        }
    }
    // 상한 안에서 끝을 못 봤다 = 값이 그보다 길다. **잘린 자리를 준다** — 라벨은 어차피 160 B 이고
    // 펼침은 파일에서 다시 읽으므로, 여기서 「없다」로 답하면 긴 명령이 통째로 목록에서 사라진다.
    if (limit > start) {
        var end = limit;
        // 이스케이프 한 쌍을 반으로 자르지 않는다.
        if (line[end - 1] == '\\') end -= 1;
        if (end > start) return .{ .start = start, .len = end - start };
    }
    return null;
}

fn appendActivity(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Hit),
    line_offset: u64,
    target: Span,
    name: Span,
    kind: Kind,
    activity: Activity,
    /// 이 호출의 id(AV2). 없거나 상한을 넘으면 **링크를 안 한다** — 잘라 비교하면 남의 결과를 집는다.
    id: ?Span,
    /// 이 호출이 적힌 **시각 키**의 자리(AV2b). 0 이면 모른다.
    time_rel: u32,
    /// 펼침이 보여 줄 명령의 자리(AV3). 0 이면 대상이 곧 명령이다.
    cmd_rel: u32,
) !void {
    if (target.len == 0) return;
    if (target.len > std.math.maxInt(u32)) return;
    // 이름은 줄 시작 상대라 u32/u16 에 담는다. 한 줄 상한(16 MiB) 안이면 도달하지 않는 방어다.
    if (name.start > std.math.maxInt(u32) or name.len > std.math.maxInt(u16)) return;
    var id_rel: u32 = 0;
    var id_len: u8 = 0;
    if (id) |v| {
        if (v.len > 0 and v.len <= max_call_id_bytes and v.start <= std.math.maxInt(u32)) {
            id_rel = @intCast(v.start);
            id_len = @intCast(v.len);
        }
    }
    try out.append(allocator, .{
        .line_offset = line_offset,
        .time_rel = time_rel,
        .cmd_rel = cmd_rel,
        .data_offset = line_offset + target.start,
        .data_len = @intCast(target.len),
        .kind = kind,
        .mime = .unknown,
        .activity = activity,
        .name_rel = @intCast(name.start),
        .name_len = @intCast(name.len),
        .id_rel = id_rel,
        .id_len = id_len,
    });
}

const Span = struct { start: usize, len: usize };

// ── AV2 · 호출과 결과를 잇는다 (계약 §3.2) ─────────────────────────────────────────────────────

/// 결과가 가리키는 **호출 id** 와 그 결말.
pub const ResultRecord = struct {
    /// 줄 안 상대 자리. 링크는 이 바이트를 **복사해** 든다 — 그 줄은 곧 이월 버퍼에서 사라진다.
    id: Span,
    summary: ResultSummary,
};

/// 이 호출이 적힌 **시각 키**의 자리(줄 시작 상대). 못 찾으면 0(모른다).
fn timestampKeyRel(line: []const u8, from: usize, window: usize) u32 {
    if (from >= line.len) return 0;
    const limit = @min(line.len, from + window);
    const at = std.mem.indexOfPos(u8, line[0..limit], from, timestamp_key) orelse return 0;
    return if (at <= std.math.maxInt(u32)) @intCast(at) else 0;
}

/// 이 줄이 **결과 레코드**면 그 id 와 요약. 아니면 null.
///
/// **호출 마커와 안 겹친다**: Codex 출력 마커는 `_output"` 까지 포함하고, Claude 결과는
/// `"type":"tool_result"` 다. 그래서 같은 줄이 호출이자 결과로 읽히지 않는다.
/// `has_image` 는 **같은 줄에서 이미지 `Hit` 이 나왔나**다. 스캐너의 이미지 패스가 이미 답한 것을
/// 그대로 받는다 — 여기서 `"type":"image"` 를 다시 찾으면 「무엇이 이미지인가」의 규칙이 두 벌이 된다.
///
/// 그 값이 필요한 이유는 **Claude 의 이미지 결과에는 본문이 없기** 때문이다: `content` 가 이미지
/// 블록만 든 배열이라(실측 542/542) `"text":` 를 못 찾아 `parsed` 가 false 가 되고, 그러면 이 함수가
/// null 을 돌려 **링크 자체가 안 선다** — 그 호출은 요약이 비고, 「전체」에서 이미지가 따로 한 줄 더
/// 뜬다(§2.2.1 이 없애려는 바로 그 중복이다).
pub fn scanResultLine(line: []const u8, line_offset: u64, has_image: bool) ?ResultRecord {
    if (line.len == 0 or line.len > max_line_bytes) return null;
    // compacted 는 이전 대화를 통째로 재수록한다 — 그 안의 결과를 세면 **지나간 호출**에 엉뚱한 결말이
    // 붙는다(이미지 패스가 같은 이유로 이 줄을 통째로 건너뛴다).
    if (isCompacted(line)) return null;
    // **창 안에서만 본다**(`result_search_window` 의 실측 근거를 참조).
    const head = line[0..@min(line.len, result_search_window)];

    if (std.mem.indexOf(u8, head, claude_tool_result_marker)) |m| {
        const id = findQuotedValueFull(line, 0, tool_use_id_key) orelse return null;
        const body = claudeBody(line, m + claude_tool_result_marker.len);
        if (!body.parsed) {
            // 본문을 못 읽었으면 「모른다」다 — 0 줄이라 적지 않는다. **다만 이미지 결과는 다르다**:
            // 본문이 없는 것이 아니라 본문이 **그림**이고, 그 사실은 이미 알고 있다.
            if (!has_image) return null;
            return .{ .id = id, .summary = .{ .found = true, .image = true } };
        }
        return .{
            .id = id,
            .summary = .{
                .found = true,
                // **provider 가 적은 것만** 믿는다(계약 §2.3) — 실측 714/40,424 가 이 필드를 든다.
                .failed = errorFlagAfter(line, body.end),
                .lines = body.lines,
                .image = has_image,
                .body = .{ .offset = line_offset + body.start },
            },
        };
    }
    if (std.mem.indexOf(u8, head, codex_custom_output_marker) orelse
        std.mem.indexOf(u8, head, codex_function_output_marker)) |m|
    {
        const id = findQuotedValueFull(line, 0, call_id_key) orelse return null;
        const body = codexBody(line, m);
        if (!body.parsed) {
            if (!has_image) return null; // 위와 같은 이유
            return .{ .id = id, .summary = .{ .found = true, .image = true } };
        }
        return .{ .id = id, .summary = .{
            .found = true,
            .failed = codexFailed(line, body.first),
            .lines = body.lines,
            .image = has_image,
            .body = .{ .offset = line_offset + body.start, .is_array = body.is_array },
        } };
    }
    return null;
}

/// 결과 본문의 **줄 수**와 **첫 줄의 자리**.
const Body = struct {
    /// 값이 **배열**인가(Codex `output`). 소비자가 원소들의 `text` 를 이어 읽어야 한다는 뜻이고,
    /// 그때 `start` 는 여는 `[` **다음**을 가리킨다.
    is_array: bool = false,
    /// 값의 **첫 바이트**(줄 안 상대). 펼침이 파일에서 그 자리부터 읽는다.
    start: usize = 0,
    /// 본문을 **실제로 찾았나**. 못 찾았으면 줄 수를 모르는 것이고, 그때 화면은 요약을 안 그린다 —
    /// 「모른다」를 `0줄` 로 적지 않는다(빈 결과의 0 줄과는 다른 사실이다).
    parsed: bool = false,
    lines: u32 = 0,
    first: Span = .{ .start = 0, .len = 0 },
    /// 값의 **끝 다음** 자리(문자열이면 닫는 따옴표). 실패 표시를 그 뒤 창에서만 찾는다.
    end: usize = 0,
};

/// 값의 첫 바이트 자리. 키는 **창 안에서** 찾는다(마커와 같은 자리에 있다 — 실측 Claude `"content":`
/// 최대 271, Codex `"output":` 중앙 194).
fn bodyValueStart(line: []const u8, from: usize, key: []const u8) ?usize {
    // ⚠️ **마커 뒤에서 찾는다.** Claude 줄에는 바깥 `message.content`(배열)가 **먼저** 나오므로, 줄
    // 머리부터 찾으면 그 배열을 본문으로 착각한다 — 그러면 줄 수가 조용히 0 이 된다(판정자가 잡았다).
    const limit = @min(line.len, from + result_search_window);
    if (from >= limit) return null;
    const k = std.mem.indexOfPos(u8, line[0..limit], from, key) orelse return null;
    const v = k + key.len;
    return if (v < line.len) v else null;
}

/// **Claude** 결과의 줄 수. 값의 **끝을 찾아 그 안만** 센다.
///
/// ⚠️ 꼬리까지 세면 안 된다 — Claude 는 `content` 뒤에 `toolUseResult` 로 **같은 텍스트를 다시** 싣는다.
/// 실측(2026-09-07): 꼬리 세기가 정확한 값과 다른 비율이 **81.1%(32,849/40,495)** 이고 대개 두 배다.
/// 값이 작아서(중앙 318 B · p99 21 KB) 끝을 찾는 대가는 싸다.
fn claudeBody(line: []const u8, from: usize) Body {
    const v = bodyValueStart(line, from, content_key_base) orelse return .{};
    switch (line[v]) {
        '"' => {
            // **여는 따옴표 다음**부터가 값이다. 빈 값(`""`)은 길이 0 이라 `spanLines` 가 0 줄로 답한다.
            const span = escapedSpanFrom(line, v + 1) orelse return .{};
            return .{
                .start = span.start,
                .parsed = true,
                .lines = spanLines(line, span),
                .first = firstLineSpan(line, span),
                .end = span.start + span.len,
            };
        },
        // 배열(text 블록) — **첫 원소만** 센다. 실측 122/40,424(0.3%)이고, 배열의 끝을 안전하게 찾으려면
        // JSON 을 실제로 파싱해야 한다(문자열 안의 `]` 때문에). 모자랄 수 있음을 여기 적어 둔다.
        '[' => {
            const span = findEscapedValueFull(line, v, text_key) orelse return .{};
            return .{
                .start = span.start,
                .parsed = true,
                .lines = spanLines(line, span),
                .first = firstLineSpan(line, span),
                .end = span.start + span.len,
            };
        },
        else => return .{},
    }
}

/// **Codex** 결과의 줄 수. 값 시작부터 **줄 끝까지** 센다 — 끝을 따로 찾지 않는다.
///
/// 실측(2026-09-07)이 이 지름길을 허락했다: 비어 있지 않은 출력 **179,396 건에서 꼬리 세기가 정확한
/// 줄 수와 완전히 같았고**, 다른 2.7% 는 전부 「빈 출력」이라 아래 빈 값 검사가 가른다. 값 뒤에 오는
/// 것은 `call_id`·`type` 뿐이라 개행이 없기 때문이다.
///
/// **왜 지름길이 필요한가**: 값의 끝을 찾으면 값 전체를 한 번 더 지나야 하는데, 3.2 GB rollout 에서
/// 그 한 패스가 초 단위다(실측). 배열 형태(135,085/184,202)에서는 원소를 이어 세야 해서 더 든다.
fn codexBody(line: []const u8, from: usize) Body {
    const v = bodyValueStart(line, from, output_key_base) orelse return .{};
    var is_array = false;
    const rest = switch (line[v]) {
        // 빈 문자열 `""` 은 **0 줄**이다(「없다」와 「한 줄」을 가른다).
        // 빈 값은 **0 줄이라는 사실**이다 — 「모른다」가 아니다.
        '"' => blk: {
            if (v + 1 < line.len and line[v + 1] == '"') return .{ .start = v + 1, .parsed = true, .end = v + 2 };
            break :blk line[v + 1 ..];
        },
        '[' => blk: {
            if (v + 1 < line.len and line[v + 1] == ']') return .{ .start = v + 1, .parsed = true, .end = v + 2 };
            is_array = true;
            break :blk line[v + 1 ..];
        },
        else => return .{},
    };
    const first = if (std.mem.indexOf(u8, rest, text_key)) |t|
        firstLineSpanIn(line, (v + 1) + t + text_key.len)
    else
        firstLineSpanIn(line, v + 1);
    // **배열이면 여는 `[` 다음부터가 본문이다** — 소비자가 원소들의 `text` 를 **순서대로 이어** 읽는다
    // (`agent_image_context.unescapeTextArray`).
    //
    // ⚠️ 예전에는 **첫 원소의 값**을 가리켰다. 그런데 실측(2026-09-09)이 그것을 기각했다: 배열
    // 151,914 건 중 **99.9%** 가 원소 둘 이상이고 첫 원소는 **99.0%** 가 `Script completed /
    // Wall time / Output:` 머리말이라, 결과 텍스트의 **0.8%** 만 보고 있었다(펼침도 검색도).
    //
    // **끝을 여기서 찾지 않는다.** 값 안의 `]` 는 이스케이프되지 않으므로 배열의 끝을 알려면 JSON 을
    // 실제로 따라가야 하는데, 그 한 패스가 3.2 GB rollout 에서 초 단위다. 소비자는 **창 하나**만
    // 보므로 거기서 따라가는 것이 싸다 — 스캐너는 자리만 든다(계약 §4.2 의 규율 그대로).
    return .{
        .start = v + 1,
        .parsed = true,
        .lines = countEscapedNewlines(rest) +| 1,
        .first = first,
        .is_array = is_array,
    };
}

/// 값 하나의 줄 수 = 이스케이프된 개행 + 1. 빈 값은 0 줄이다(「없다」와 「한 줄」을 가른다).
fn spanLines(line: []const u8, v: Span) u32 {
    if (v.len == 0) return 0;
    return countEscapedNewlines(line[v.start .. v.start + v.len]) +| 1;
}

fn firstLineSpan(line: []const u8, v: Span) Span {
    const s = line[v.start .. v.start + v.len];
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '\\')) |b| {
        if (b + 1 >= s.len) break;
        if (s[b + 1] == 'n') return .{ .start = v.start, .len = b };
        i = b + 2;
    }
    return v;
}

/// 끝을 모르는 자리에서의 **첫 줄** — 개행이나 값의 닫는 따옴표 중 먼저 오는 곳까지다.
fn firstLineSpanIn(line: []const u8, start: usize) Span {
    if (start >= line.len) return .{ .start = start, .len = 0 };
    const s = line[start..];
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => {
                if (i + 1 < s.len and s[i + 1] == 'n') return .{ .start = start, .len = i };
                i += 1;
            },
            '"' => return .{ .start = start, .len = i },
            else => {},
        }
    }
    return .{ .start = start, .len = s.len };
}

/// **이스케이프를 인지해** 개행(`\n`)을 센다.
///
/// ⚠️ 그냥 `\n` 을 세면 안 된다 — 실측(2026-09-07)에서 **Codex 결과의 24.0%** 가 `\\n`(백슬래시 자체를
/// 이스케이프한 것)이었다. 코드·경로가 담긴 출력에 흔하고, 그것을 개행으로 세면 「3 줄」이 「12 줄」이 된다.
/// Claude 는 0.9% 라 티가 덜 나지만 규칙은 하나여야 한다.
fn countEscapedNewlines(s: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '\\')) |b| {
        if (b + 1 >= s.len) break;
        if (s[b + 1] == 'n') n +|= 1;
        // 이스케이프된 **한 글자**를 건너뛴다. 이것이 `\\n` 을 개행으로 안 세는 유일한 이유다.
        i = b + 2;
    }
    return n;
}

/// Claude 의 실패 표시. **본문 값이 끝난 자리 뒤 창에서만** 찾는다.
///
/// ⚠️ 줄 전수로 훑으면 결과 하나가 616 KB 까지 가는 자리에서 그 자체가 스캔 비용이 된다. 실측
/// (2026-09-07): `is_error":true` 는 **715/715 가 `content` 값 뒤**이고 거리가 **중앙·p99·최대 모두
/// 2 바이트**다(JSON 의 `","` 하나). 창 512 B 는 그 256 배다.
fn errorFlagAfter(line: []const u8, end: usize) bool {
    if (end >= line.len) return false;
    const limit = @min(line.len, end + result_search_window);
    return std.mem.indexOf(u8, line[end..limit], is_error_true) != null;
}

/// Codex 가 **자기가 적은** 실패 표시인가. 명령이나 출력을 해석하지 않는다(계약 §2.3) — 결과의 **첫
/// 줄**이 도구가 쓴 상태 줄일 때만 본다.
///
/// 실측(첫 줄 분포): `Exit code: 0` 7,076 · `exit=0` 504 · `exit=1` 255 · `exit=8` 60 ·
/// `exit=undefined` 594 · `exit=running` 55. 두 표기가 다 있고, **숫자가 0 이 아닐 때만** 실패다
/// (`undefined`·`running` 은 끝나지 않은 것이라 실패가 아니다).
fn codexFailed(line: []const u8, first: Span) bool {
    if (first.len == 0) return false;
    const s = line[first.start .. first.start + first.len];
    const digits = if (std.mem.startsWith(u8, s, "Exit code: "))
        s["Exit code: ".len..]
    else if (std.mem.startsWith(u8, s, "exit="))
        s["exit=".len..]
    else
        return false;
    var seen_digit = false;
    var nonzero = false;
    for (digits) |c| {
        if (c < '0' or c > '9') break;
        seen_digit = true;
        if (c != '0') nonzero = true;
    }
    return seen_digit and nonzero;
}

/// `findQuotedValue` 의 **창 없는** 판. 결과 레코드의 id 는 줄 머리에서 멀 수 있다 — 실측
/// `tool_use_id` 최대 4,571 · Codex `call_id` 최대 7,884,001 이라 512 B 창으로는 못 찾는다.
/// 한 줄에 레코드가 하나라(계약 §3.1) 줄 전체를 봐도 남의 값을 집지 않는다.
fn findQuotedValueFull(line: []const u8, from: usize, key: []const u8) ?Span {
    const k = std.mem.indexOfPos(u8, line, from, key) orelse return null;
    const start = k + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    return .{ .start = start, .len = end - start };
}

/// `findEscapedValue` 의 **끝까지** 판. 줄 수를 세려면 값 전체가 필요하다(라벨과 달리 잘린 자리로는
/// 셀 수 없다). 끝은 **여는 따옴표의 짝**이고, 그 앞 백슬래시가 홀수면 그 따옴표는 값의 일부다.
fn findEscapedValueFull(line: []const u8, from: usize, key: []const u8) ?Span {
    const k = std.mem.indexOfPos(u8, line, from, key) orelse return null;
    return escapedSpanFrom(line, k + key.len);
}

/// 여는 따옴표 **다음** 자리(`value_start`)부터 값의 끝까지. 끝은 **짝이 맞는 따옴표**이고, 그 앞
/// 백슬래시가 홀수면 그 따옴표는 값의 일부다.
fn escapedSpanFrom(line: []const u8, value_start: usize) ?Span {
    var i = value_start;
    while (std.mem.indexOfScalarPos(u8, line, i, '"')) |q| {
        var b = q;
        var bs: usize = 0;
        while (b > value_start and line[b - 1] == '\\') : (bs += 1) b -= 1;
        if (bs % 2 == 0) return .{ .start = value_start, .len = q - value_start };
        i = q + 1;
    }
    return null;
}

/// `from`부터 `key_search_window` 안에서 `key`를 찾고, 그 뒤 따옴표 값의 범위를 돌려준다.
/// base64와 mime 문자열에는 JSON 이스케이프가 없으므로 다음 `"`가 곧 끝이다.
fn findQuotedValue(line: []const u8, from: usize, key: []const u8) ?Span {
    const limit = @min(line.len, from + key_search_window);
    const k = std.mem.indexOfPos(u8, line[0..limit], from, key) orelse return null;
    const start = k + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    return .{ .start = start, .len = end - start };
}

fn append(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Hit),
    line_offset: u64,
    span: Span,
    kind: Kind,
    mime: Mime,
) !void {
    if (span.len == 0) return;
    if (span.len > std.math.maxInt(u32)) return; // 방어 — 한 줄 상한 안이면 도달하지 않는다
    try out.append(allocator, .{
        .line_offset = line_offset,
        .data_offset = line_offset + span.start,
        .data_len = @intCast(span.len),
        .kind = kind,
        .mime = mime,
    });
}

/// 완결된 줄들로 채워진 버퍼 전체를 훑는다. **마지막 줄이 개행으로 끝나지 않으면 그 줄은 보지 않는다** —
/// 잘린 꼬리를 파싱하면 반쪽 base64를 이미지로 셀 수 있다. 증분 읽기의 `last_offset` 규율(§4.2)과 같은 이유다.
///
/// 돌려주는 값은 **소비한 바이트 수**(= 마지막 개행 다음 위치)다. 호출자는 그것을 `last_offset`에 더한다.
pub fn scanBuffer(
    allocator: std.mem.Allocator,
    buf: []const u8,
    base_offset: u64,
    out: *std.ArrayList(Hit),
) !usize {
    var consumed: usize = 0;
    while (std.mem.indexOfScalarPos(u8, buf, consumed, '\n')) |nl| {
        const line = buf[consumed..nl];
        try scanLine(allocator, line, base_offset + consumed, out);
        consumed = nl + 1;
    }
    return consumed;
}

/// 한 파일에서 담는 이미지 자리의 상한. **악의적/손상 파일이 메모리를 무한히 먹지 않게** 하는 방어다.
/// 실측(2026-08-29)에서 한 파일 최대가 770개(Codex rollout)였으므로 4096이면 실사용을 자르지 않는다.
/// 넘치면 `partial` 로 표시하고 더 담지 않는다 — 조용히 자르지 않는다.
pub const max_hits_per_file: usize = 4096;

/// 한 파일에서 담는 **활동** 자리의 상한. 이미지와 **따로** 센다.
///
/// **한 통으로 세면 갤러리가 조용히 빈다.** 활동은 세션당 최대 12,200개인데(활동 뷰 계약 §4.2) 이미지는
/// 한 파일 최대 770개다. 같은 4096 을 나눠 쓰면 활동이 상한을 채운 파일에서 **이미지가 밀려나고**,
/// 사용자에게는 「이미지가 없습니다」로 보인다 — 고장과 구분되지 않는 종류의 실패다.
///
/// **이 상한은 「최근 N 개」다 — 「앞에서부터 N 개」가 아니다.** 넘치면 오래된 쪽을 버린다(아래
/// `evictOldestActivities`).
///
/// ⚠️ **실측이 처음 근거를 뒤집었다.** 12 세션 표본의 최대(12,200)를 보고 「그 1.34 배」로 정했는데,
/// 이 맥의 최악 rollout 은 활동이 **181,907 건**(상한의 **11.1 배**)이다. 상한을 올려 쫓는 대신
/// **무엇을 남길지**를 고쳤다 — 더 큰 파일이면 어차피 또 넘고, 사용자가 찾는 것은 최근이다.
/// `Hit` 이 32 바이트 미만이므로 16,384개라도 512 KB 다.
pub const max_activity_hits_per_file: usize = 16384;

/// 호출 id 의 최대 길이(AV2). 실측(2026-09-07): Claude 는 30 고정, Codex 는 29 또는 41(최대 41).
/// 그 1.17 배다. **넘는 id 는 링크하지 않는다** — 잘라서 비교하면 남의 결과를 집는다.
pub const max_call_id_bytes: usize = 48;

/// 결과를 기다리는 호출을 몇 개까지 들고 있나. 실측 호출→결과 거리는 Claude 중앙 1 · Codex 중앙 3 ·
/// **최대 48 줄**이라 그 5 배가 넘는다. 넘치면 가장 오래된 것을 덮는다 — 그 자리는 이미 결과가 없는
/// 호출(취소)일 가능성이 크고, 결과는 늘 가까이 오기 때문이다.
///
/// **줄 창이 아니라 개수 창이다**(계약 §3.2 — 「줄 수로 창을 고정하지 않는다」). 사이에 `reasoning` 이
/// 몇 줄 끼든 그 사이에 **다른 호출이 256 개** 들어오지 않는 한 링크는 산다.
pub const max_pending_calls: usize = 256;

/// 결과를 기다리는 호출 하나. id 는 **사본**이다 — 그 줄은 곧 이월 버퍼에서 사라진다.
const PendingCall = struct {
    id: [max_call_id_bytes]u8 = undefined,
    /// 0 이면 죽은 자리(이미 결말이 붙었다).
    id_len: u8 = 0,
    hit_index: u32 = 0,
};

/// 청크로 흘러오는 파일을 줄 경계로 이어 붙여 훑는다.
///
/// **이 타입이 있는 이유는 청크 경계다.** 64 KiB 씩 읽으면 마커도 base64 도 경계에 걸린다. 걸친 조각을
/// 다음 청크 앞에 이어 붙이지 않으면 그 이미지는 **없는 것이 된다**. 반대로 걸친 조각을 그대로 훑으면
/// 반쪽을 세거나, 다음 회차가 같은 것을 또 센다(§4.2 의 `last_offset` 규율과 같은 이유).
///
/// I/O 를 모른다 — 호출자가 읽어서 `feed` 한다. 그래서 경계 처리를 파일 없이 시험할 수 있다.
pub const StreamScanner = struct {
    /// 개행을 못 만난 꼬리. 다음 청크 앞에 붙는다.
    carry: std.ArrayList(u8) = .empty,
    /// 파일에서 **소비한** 바이트(= 마지막 개행 다음). 이어읽기(IG2)가 `last_offset` 으로 쓴다.
    consumed: u64 = 0,
    /// 상한·손상으로 못 본 것이 있다. 「비었다」와 「못 봤다」는 다른 사실이라 나눠 든다.
    partial: bool = false,
    /// 이미지를 다 못 담았다(`max_hits_per_file`).
    ///
    /// **종류를 가르는 이유**: 활동만 잘렸는데 이미지 필터에서 「다 읽지 못했습니다」가 뜨면 그것은
    /// 거짓말이다 — 실측 최악 파일에서 활동은 91% 가 잘리지만 이미지 27 장은 전부 들어온다.
    image_partial: bool = false,
    /// 활동을 다 못 담았다 — 오래된 쪽을 버렸다는 뜻이다(최신은 남아 있다).
    activity_partial: bool = false,
    /// 지금까지 담은 이미지 수. **상한을 종류별로 세기 위해** 든다(`max_hits_per_file`).
    image_count: usize = 0,
    /// 지금까지 담은 활동 수(`max_activity_hits_per_file`).
    activity_count: usize = 0,
    /// 이월 버퍼를 앞으로 당긴 **횟수**. 진단용이자 회귀 가드다 — 개행을 못 만난 청크에서 이 값이
    /// 오르면 긴 줄 하나가 O(N²) 로 바이트를 옮기고 있다는 뜻이다(실측 52.9 초 → 10.1 초 수정).
    carry_moves: u64 = 0,
    /// 아직 결과를 못 만난 호출들(AV2). **링 버퍼다** — 넘치면 가장 오래된 것을 덮는다.
    pending: std.ArrayList(PendingCall) = .empty,
    /// 링의 가장 오래된 자리. `pending` 이 상한에 닿기 전에는 언제나 0 이다.
    pending_head: usize = 0,
    /// **살아 있는** 기다림의 수(죽은 자리를 뺀 것). 0 이면 결과 줄을 볼 이유가 아예 없다 —
    /// 그 짧은 회로가 큰 파일에서 결과 탐색을 통째로 건너뛴다.
    pending_live: usize = 0,
    /// 지금 훑고 있는 파일이 `Chain` 의 몇 번째인가. **받아들이는 `Hit` 마다 여기서 찍는다.**
    ///
    /// ⚠️ **호출자가 사후에 찍으면 안 된다.** 예전에는 백엔드가 파일마다 `hits.items.len` 을 잡아
    /// 두고 스캔이 끝난 뒤 그 뒤쪽에 번호를 찍었는데, **퇴출은 배열을 제자리 압축한다** — 앞 파일
    /// 항목이 버려지면 살아남은 것들이 앞으로 당겨지고, 그만큼 이 파일의 앞부분이 그 자리 **밖**으로
    /// 밀려 번호를 못 받는다(기본값 0 = 첫 파일로 읽힌다). 그러면 라벨·펼침·디코드가 **엉뚱한 파일**의
    /// 바이트를 읽는다.
    ///
    /// 스탬프가 `Hit` 과 함께 움직이면 압축이 무의미해진다. 대기 링(`remapPendingAfterEvict`)과
    /// 접기(`remapFoldsAfterEvict`)가 자리를 **따라가야** 했던 것과 달리, 이쪽은 애초에 자리에
    /// 매이지 않는 것이 답이다.
    file_index: u8 = 0,

    pub fn deinit(self: *StreamScanner, allocator: std.mem.Allocator) void {
        self.carry.deinit(allocator);
        self.pending.deinit(allocator);
        self.* = .{};
    }

    /// 방금 줄에서 나온 `Hit` 들을 **종류별 상한 안에서만** 받아들인다.
    ///
    /// 넘친 것은 버리고 `partial` 로 밝힌다 — 「없다」와 「못 봤다」를 가르는 계약이다. 잘라내기가
    /// 아니라 **골라 담기**인 이유는 한 줄에서 두 종류가 함께 나올 수 있기 때문이다: 한쪽이 넘쳤다고
    /// 뒤를 통째로 자르면 아직 자리가 남은 다른 종류까지 잃는다.
    /// 상한을 넘은 활동에서 **오래된 절반을 버린다.** 한 개씩 버리면 배열 앞 이동이 매번 O(n) 이라
    /// O(n²) 가 된다 — 절반씩이면 amortized O(1) 이다.
    ///
    /// **왜 오래된 쪽인가.** 이 뷰의 물음은 「**아까** 그 명령 뭐였지」다. 앞에서 채우고 넘치면
    /// 버리는 방식은 그 물음의 **정반대**를 답한다 — 갤러리가 IG7 에서 똑같이 겪었다(151 장 중
    /// 4 장만 보이는데 그 4 장이 세션 맨 처음 것이었다). 실측 최악 세션은 활동이 상한의 11.1 배라
    /// 이 선택이 곧 기능의 쓸모다.
    /// ⚠️ **이 함수는 `out` 의 인덱스를 무효화한다** — 제자리 압축이라 살아남은 항목의 자리가 앞으로
    /// 당겨진다. 그 배열을 가리키는 인덱스를 드는 소비자(AV2 의 대기 링)는 `remapPendingAfterEvict`
    /// 로 다시 맞춰야 한다. 버린 개수를 돌려주는 이유가 그것이다.
    fn evictOldestActivities(self: *StreamScanner, out: *std.ArrayList(Hit)) usize {
        // **1/8 씩 버린다.** 절반씩 버리면 항목 수가 8,192 ~ 16,384 를 오가 최악에는 상한의 절반만
        // 남는다 — 1/8 이면 14,336 ~ 16,384 로 유지되고 amortized 비용은 그대로다(퇴출 한 번에
        // O(n), 그 사이 n/8 개를 받으므로 항목당 상수).
        const drop = self.activity_count / 8;
        if (drop == 0) return 0;
        var dropped: usize = 0;
        var boundary: usize = 0; // 마지막으로 버린 **옛 인덱스**
        var w: usize = 0;
        for (out.items, 0..) |h, i| {
            if (!h.kind.isImage() and dropped < drop) {
                dropped += 1;
                boundary = i;
                continue;
            }
            out.items[w] = h;
            w += 1;
        }
        out.shrinkRetainingCapacity(w);
        self.activity_count -= dropped;
        self.activity_partial = true;
        self.partial = true;
        self.remapPendingAfterEvict(boundary, dropped);
        remapFoldsAfterEvict(out, boundary, dropped);
        return dropped;
    }

    /// 퇴출이 `out` 을 압축한 뒤 **접힌 이미지의 주인을 다시 맞춘다**(§2.2.1).
    ///
    /// ⚠️ 대기 링과 **같은 이유**로 필요하다 — 제자리 압축이 인덱스를 전부 무효화한다. 다만 이쪽은
    /// 결과가 더 나쁘다: 대기 링이 어긋나면 남의 줄에 결말이 붙지만, 접기가 어긋나면 **엉뚱한 호출로
    /// 접히거나**, 주인이 버려진 이미지가 「전체」에서 **통째로 사라진다**.
    ///
    /// 주인을 잃은 이미지는 **접기를 푼다** — 그때 그 이미지는 더 이상 남의 줄과 겹치지 않으므로
    /// 「전체」에 제 줄로 서는 것이 맞다.
    fn remapFoldsAfterEvict(out: *std.ArrayList(Hit), boundary: usize, dropped: usize) void {
        if (dropped == 0) return;
        for (out.items) |*h| {
            if (h.fold_owner == no_fold) continue;
            if (h.fold_owner <= boundary) {
                h.fold_owner = no_fold; // 주인이 버려졌다
                continue;
            }
            h.fold_owner -= @intCast(dropped);
        }
    }

    /// 방금 줄에서 나온 `Hit` 들을 받아들인다.
    ///
    /// **이미지와 활동의 규율이 다르다.** 이미지는 상한에서 **더 안 받는다**(격자는 최신 우선 정렬이
    /// 뒤에서 이뤄지고, 실측상 한 파일 최대가 770 장이라 상한에 잘 안 닿는다). 활동은 상한의 11 배가
    /// 오는 파일이 있으므로 **일단 받고 오래된 쪽을 버린다** — 그래야 최신이 남는다.
    /// 돌려주는 것은 **새로 받은 것들의 시작 인덱스**다 — 퇴출이 앞을 지웠으면 `before` 는 이미
    /// 낡았다(AV2 의 링크가 그 범위를 쓴다).
    fn admit(self: *StreamScanner, out: *std.ArrayList(Hit), before: usize) usize {
        var w = before;
        for (out.items[before..]) |src| {
            var h = src;
            // **받아들이는 자리에서 찍는다.** 여기가 「이 스캐너가 이 히트를 자기 것으로 삼는」
            // 유일한 길목이고, 그 뒤로는 어떤 압축이 와도 스탬프가 값과 함께 움직인다.
            h.file_index = self.file_index;
            if (h.kind.isImage()) {
                if (self.image_count >= max_hits_per_file) {
                    self.image_partial = true;
                    self.partial = true;
                    continue;
                }
                self.image_count += 1;
            } else {
                self.activity_count += 1;
            }
            out.items[w] = h;
            w += 1;
        }
        out.shrinkRetainingCapacity(w);
        if (self.activity_count > max_activity_hits_per_file) {
            // 퇴출은 **앞**을 지운다 — 방금 받은 것들의 자리도 그만큼 당겨진다.
            return before -| self.evictOldestActivities(out);
        }
        return before;
    }

    /// 이 줄이 결과 레코드면 **앞서 담은 호출**에 결말을 붙인다(계약 §3.2).
    ///
    /// **줄 수로 창을 고정하지 않는다** — Codex 는 사이에 `reasoning` 이 끼어 최대 48 줄 뒤다. 대신
    /// 기다리는 호출의 **개수**로 유계다(`max_pending_calls`).
    fn linkResult(
        self: *StreamScanner,
        line: []const u8,
        line_offset: u64,
        out: *std.ArrayList(Hit),
        added_from: usize,
    ) void {
        // **기다리는 호출이 없으면 결과를 볼 이유가 없다.** 결과 탐색은 줄마다 도는 일이라, 이 한 줄이
        // 상한에 걸린 큰 파일에서 그 비용을 통째로 없앤다.
        if (self.pending_live == 0) return;
        // **이 줄에서 이미지가 나왔나**는 이미 답이 나와 있다(위의 `scanLine`). 그 사실을 결과 해석에
        // 넘긴다 — 줄을 다시 뒤져 마커를 찾으면 규칙이 두 벌이 된다.
        var has_image = false;
        for (out.items[@min(added_from, out.items.len)..]) |h| {
            if (h.kind.isImage()) {
                has_image = true;
                break;
            }
        }
        const rec = scanResultLine(line, line_offset, has_image) orelse return;
        const id = line[rec.id.start .. rec.id.start + rec.id.len];
        const idx = self.takePending(id) orelse return;
        if (idx >= out.items.len) return;
        out.items[idx].result = rec.summary;
        if (!has_image) return;
        // **이 줄의 이미지들은 그 호출의 결과다.** 「전체」가 이 표시로 접는다(§2.2.1).
        //
        // 한 줄의 이미지 전부에 같은 주인을 준다 — 실측(542/542)에서 이미지 결과의 `content` 는
        // **이미지 블록만** 들고, 사본(`toolUseResult`)은 그 앞에서 이미 접혔다.
        var first_image = true;
        for (out.items[@min(added_from, out.items.len)..]) |*h| {
            if (!h.kind.isImage()) continue;
            h.fold_owner = idx;
            // **첫 장의 자리를 호출이 든다**(AV5). 실측(542/542)에서 이미지 결과의 `content` 는
            // 그림 하나만 들지만, 여럿이면 줄 하나에 하나만 붙일 수 있으므로 **처음 것**으로 정한다.
            if (first_image) {
                first_image = false;
                out.items[idx].result.image_offset = h.data_offset;
                out.items[idx].result.image_len = h.data_len;
                out.items[idx].result.image_file = h.file_index;
            }
        }
    }

    /// 방금 담은 호출들의 id 를 **복사해** 든다. 그 줄은 다음 청크에서 이월 버퍼와 함께 사라진다.
    fn noteCalls(
        self: *StreamScanner,
        allocator: std.mem.Allocator,
        line: []const u8,
        out: *std.ArrayList(Hit),
        from: usize,
    ) !void {
        for (out.items[from..], from..) |h, i| {
            // **id 는 그 호출이 스스로 든다**(`id_rel`/`id_len`). 줄에서 다시 찾으면 한 줄에 호출이
            // 둘일 때 남의 id 를 집는다 — 라벨이 같은 이유로 이미 범위를 닫았다.
            if (h.kind.isImage() or h.id_len == 0) continue;
            const end: usize = @as(usize, h.id_rel) + h.id_len;
            if (end > line.len) continue;
            const id = line[h.id_rel..end];
            if (i > std.math.maxInt(u32)) continue;
            var e: PendingCall = .{ .id_len = @intCast(id.len), .hit_index = @intCast(i) };
            @memcpy(e.id[0..id.len], id);
            if (self.pending.items.len < max_pending_calls) {
                try self.pending.append(allocator, e);
                self.pending_live += 1;
            } else {
                // 덮는 자리가 아직 살아 있었으면 그 하나가 죽는다(수가 안 는다).
                if (self.pending.items[self.pending_head].id_len == 0) self.pending_live += 1;
                self.pending.items[self.pending_head] = e;
                self.pending_head = (self.pending_head + 1) % max_pending_calls;
            }
        }
    }

    /// 이 id 를 기다리던 호출의 자리. **최신부터** 본다 — 결과는 대개 바로 다음 줄이다(실측 중앙 1).
    ///
    /// 찾은 자리는 **죽인다**: 같은 id 의 두 번째 결과가 와도 앞의 것을 덮지 않는다.
    fn takePending(self: *StreamScanner, id: []const u8) ?u32 {
        const n = self.pending.items.len;
        if (n == 0) return null;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const idx = (self.pending_head + n - 1 - k) % n;
            const e = &self.pending.items[idx];
            if (e.id_len == 0) continue;
            if (std.mem.eql(u8, e.id[0..e.id_len], id)) {
                e.id_len = 0;
                self.pending_live -= 1;
                return e.hit_index;
            }
        }
        return null;
    }

    /// 퇴출이 `out` 을 압축한 뒤 **대기 인덱스를 다시 맞춘다**(AV2).
    ///
    /// ⚠️ `evictOldestActivities` 는 `out` 을 제자리 압축하므로 **그 배열을 가리키던 인덱스를 전부
    /// 무효화한다.** 대기 링이 그런 인덱스를 드는 **첫 소비자**라, 이 자리가 없으면 퇴출 뒤에 온
    /// 결과가 **남의 줄에 결말을 붙인다**(상한의 11 배가 오는 파일이 실제로 있다).
    ///
    /// `boundary` 는 마지막으로 버린 **옛 인덱스**다. 대기 항목은 언제나 활동이므로, 그 이하면 그
    /// 호출 자체가 버려진 것이고(죽인다) 넘으면 버린 개수만큼 당기면 된다.
    fn remapPendingAfterEvict(self: *StreamScanner, boundary: usize, dropped: usize) void {
        if (dropped == 0) return;
        for (self.pending.items) |*e| {
            if (e.id_len == 0) continue;
            if (e.hit_index <= boundary) {
                e.id_len = 0;
                self.pending_live -= 1;
                continue;
            }
            e.hit_index -= @intCast(dropped);
        }
    }

    /// 청크 하나를 먹인다. `chunk` 는 `self.consumed + self.carry.len` 위치부터의 바이트여야 한다.
    pub fn feed(
        self: *StreamScanner,
        allocator: std.mem.Allocator,
        chunk: []const u8,
        out: *std.ArrayList(Hit),
    ) !void {
        if (chunk.len == 0) return;
        // **이전 이월 버퍼에는 개행이 없다** — 있었으면 그때 소비됐다. 그래서 새로 붙은 곳부터만 찾는다.
        //
        // 처음에는 매번 `used`(=0)부터 찾았는데, 그것이 **O(n²)** 였다: 6.9 MB 짜리 줄은 64 KiB 청크
        // 108 개로 쌓이고 그때마다 이월 전체를 다시 훑어 **한 줄에 373 MB** 를 스캔한다. 실측 파일에
        // 1 MB 넘는 줄이 17 개라 120 MB 파일 하나가 0.3 초가 아니라 십수 초였다.
        const old_len = self.carry.items.len;
        try self.carry.appendSlice(allocator, chunk);
        const base = self.consumed;
        const buf = self.carry.items;

        var used: usize = 0;
        var search: usize = old_len;
        while (std.mem.indexOfScalarPos(u8, buf, search, '\n')) |nl| {
            if (self.image_count < max_hits_per_file or self.activity_count < max_activity_hits_per_file) {
                const before = out.items.len;
                const line = buf[used..nl];
                // ⚠️ **compacted 를 가장 먼저 본다.** `scanLine` 이 그 줄에서 곧장 되돌아가는 것과 같은
                // 이유이고(그 줄이 실측 파일 바이트의 41%), AV2 의 링크를 그 앞에 두면 그 절약이 통째로
                // 사라진다 — 실측으로 3.2 GB 파일에서 그 실수가 +1.4 초였다.
                const skip = isCompacted(line);
                try scanLine(allocator, line, base + used, out);
                // 퇴출이 돌면 `before` 가 낡는다 — 새로 받은 것의 시작을 `admit` 이 알려 준다.
                const added_from = self.admit(out, before);
                if (!skip) {
                    // **결과를 먼저, 호출을 나중에.** 한 줄이 둘 다일 수는 없지만(마커가 배타적이다),
                    // 순서를 이렇게 두면 「자기 자신에게 결말을 붙이는」 경로가 원리적으로 없다.
                    self.linkResult(line, base + used, out, added_from);
                    try self.noteCalls(allocator, line, out, added_from);
                }
            } else {
                self.partial = true;
            }
            used = nl + 1;
            search = used;
        }

        // 소비한 만큼 앞을 버리고 꼬리만 남긴다.
        //
        // **아무것도 안 소비했으면 옮길 것도 없다.** 이 `if` 가 없으면 개행을 못 만난 청크마다 버퍼
        // **전체**를 자기 자신에게 memcpy 한다 — 긴 줄 하나가 64 KiB 청크 N 개로 쌓이는 동안
        // O(N²) 바이트를 옮긴다. 실측(1,980 MB 파일): 이 한 줄로 **52.9 초 → 아래 참조**.
        self.consumed += used;
        if (used > 0) {
            self.carry_moves += 1;
            const rest = buf.len - used;
            std.mem.copyForwards(u8, self.carry.items[0..rest], buf[used..]);
            self.carry.shrinkRetainingCapacity(rest);
        }

        // **꼬리가 한 줄 상한을 넘으면 그 줄을 버린다.** 개행 없는 바이트가 무한히 오면(손상 파일·바이너리)
        // 이 버퍼가 파일 크기만큼 자란다. 버리는 대신 `partial` 로 밝힌다.
        if (self.carry.items.len > max_line_bytes) {
            self.consumed += self.carry.items.len;
            self.carry.clearRetainingCapacity();
            self.partial = true;
        }
    }
};

// ── 테스트 ─────────────────────────────────────────────────────────────────────
//
// **구조는 실측, 값은 합성**(계획 §P2). 아래 fixture 의 레코드 모양은 2026-08-29 에 실제 provider 기록에서
// 확인한 것이고, base64 payload 와 문구만 합성이다. 사용자 기록을 fixture 로 커밋하지 않는다(계약 §6).

const testing = std.testing;

fn collect(src: []const u8) !std.ArrayList(Hit) {
    var out: std.ArrayList(Hit) = .empty;
    errdefer out.deinit(testing.allocator);
    _ = try scanBuffer(testing.allocator, src, 0, &out);
    return out;
}

test "Claude user 메시지의 이미지를 찾는다 — 실측 레코드 모양" {
    const line =
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"이거 봐주세요"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAABBBBCCCC"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Kind.claude_image, hits.items[0].kind);
    try testing.expectEqual(Mime.png, hits.items[0].mime);
    try testing.expectEqual(@as(u32, 12), hits.items[0].data_len);
    try testing.expectEqualStrings(
        "AAAABBBBCCCC",
        line[hits.items[0].data_offset .. hits.items[0].data_offset + hits.items[0].data_len],
    );
    try testing.expectEqual(@as(u64, 0), hits.items[0].line_offset);
}

test "media_type 이 없는 tool_result 이미지도 찾는다" {
    // 실측: tool_result 안의 image 는 media_type 없이 오기도 한다.
    const line =
        \\{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"ZZZZ"}}]}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Mime.unknown, hits.items[0].mime);
    try testing.expectEqualStrings("ZZZZ", line[hits.items[0].data_offset..][0..4]);
}

test "toolUseResult 2중 저장을 별도 kind 로 잡는다" {
    const line =
        \\{"type":"user","toolUseResult":{"type":"image","file":{"base64":"DUPDUPDUP","type":"image/png"}}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Kind.claude_tool_file, hits.items[0].kind);
    try testing.expectEqualStrings("DUPDUPDUP", line[hits.items[0].data_offset..][0..9]);
}

test "Codex input_image 는 data URL 접두를 벗기고 payload 만 가리킨다" {
    // 실측 모양(통제 입력으로 확인): input_text(<image name=… path=…>) → input_image → input_text(</image>) → input_text(질문)
    const line =
        \\{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<image name=[Image #1] path=\"/x/y.png\">"},{"type":"input_image","image_url":"data:image/png;base64,QQQQRRRR"},{"type":"input_text","text":"</image>"},{"type":"input_text","text":"이거 뭐예요"}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Kind.codex_input_image, hits.items[0].kind);
    try testing.expectEqual(Mime.png, hits.items[0].mime);
    try testing.expectEqualStrings("QQQQRRRR", line[hits.items[0].data_offset..][0..8]);
}

test "Codex compacted 줄은 통째로 건너뛴다 — 이미지가 들어 있어도" {
    // 실측: compacted 레코드가 이전 대화를 이미지째 재수록한다(한 레코드 7.2 MB, 한 파일 376개).
    const line =
        \\{"type":"compacted","payload":{"message":"…{\"type\": \"input_image\", \"image_url\": \"data:image/png;base64,XXXX\"}…","content":[{"type":"input_image","image_url":"data:image/png;base64,YYYY"}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "한 줄에 이미지가 여럿이면 각각 잡고 오프셋이 겹치지 않는다" {
    const line =
        \\{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"BBBBBB"}}]}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits.items.len);
    try testing.expectEqual(Mime.png, hits.items[0].mime);
    try testing.expectEqual(Mime.jpeg, hits.items[1].mime);
    try testing.expect(hits.items[0].data_offset + hits.items[0].data_len <= hits.items[1].data_offset);
}

test "줄 오프셋은 파일 절대값이다 — 여러 줄" {
    const first =
        \\{"type":"user","message":{"content":[{"type":"text","text":"앞줄"}]}}
    ;
    const second =
        \\{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"CCCC"}}]}
    ;
    const src = first ++ "\n" ++ second ++ "\n";
    var hits = try collect(src);
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(@as(u64, first.len + 1), hits.items[0].line_offset);
    try testing.expectEqualStrings("CCCC", src[hits.items[0].data_offset..][0..4]);
}

test "개행으로 끝나지 않은 꼬리는 보지 않는다 — 안 그러면 다음 회차가 같은 이미지를 또 센다" {
    const complete =
        \\{"content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}]}
    ;
    // **위험은 반쪽 base64 가 아니라 중복이다.** 꼬리가 잘렸어도 그 안에 이미 **완결된** 이미지 레코드가
    // 들어 있을 수 있다(한 줄에 이미지가 여럿인 경우). 그것을 세면, 다음 회차가 이 줄을 처음부터 다시
    // 읽을 때 같은 이미지를 두 번째로 센다 — `last_offset` 을 개행까지만 전진시키는 이유다(§4.2).
    const partial = "{\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"TAIL\"}},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"CUT";
    const src = complete ++ "\n" ++ partial;

    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);
    const consumed = try scanBuffer(testing.allocator, src, 0, &out);

    // 완결된 첫 줄의 하나만 센다. 꼬리의 "TAIL" 은 **완결돼 있어도** 세지 않는다.
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("AAAA", src[out.items[0].data_offset..][0..4]);
    try testing.expectEqual(@as(usize, complete.len + 1), consumed);
}

test "본문이 마커 글자를 언급해도 오탐이 없다 — JSON 이스케이프가 막는다" {
    // 이 대화 자체가 그렇다: 마커를 설명하는 텍스트가 트랜스크립트에 들어간다.
    const line =
        \\{"type":"user","message":{"content":[{"type":"text","text":"마커는 \"type\":\"image\",\"source\":{\"type\":\"base64\" 이고 data 키를 본다"}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "빈 줄과 상한을 넘는 줄은 조용히 건너뛴다" {
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);
    try scanLine(testing.allocator, "", 0, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    const huge = try testing.allocator.alloc(u8, max_line_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    try scanLine(testing.allocator, huge, 0, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "Kind 는 provider 를 안다" {
    try testing.expectEqual(Provider.claude, Kind.claude_image.provider());
    try testing.expectEqual(Provider.claude, Kind.claude_tool_file.provider());
    try testing.expectEqual(Provider.codex, Kind.codex_input_image.provider());
}

test "Source: 경로를 담고, 바뀔 때만 true 를 돌려준다" {
    var src: Source = .{};
    try testing.expect(src.isEmpty());
    try testing.expect(src.set("/Users/u/.claude/projects/p/a.jsonl"));
    try testing.expectEqualStrings("/Users/u/.claude/projects/p/a.jsonl", src.path());
    // 같은 값이면 바뀐 것이 아니다 — 인덱스를 헛되이 버리지 않는다.
    try testing.expect(!src.set("/Users/u/.claude/projects/p/a.jsonl"));
    try testing.expect(src.set("/Users/u/.claude/projects/p/b.jsonl"));
    try testing.expectEqualStrings("/Users/u/.claude/projects/p/b.jsonl", src.path());
}

test "Source: 상한 초과·상대 경로·빈 값은 담지 않고 비운다 — 자르지 않는다" {
    var src: Source = .{};
    _ = src.set("/ok/a.jsonl");

    // 자르면 없는 파일이거나 **다른 파일**이 된다.
    const too_long = "/" ++ ("x" ** max_source_path_bytes);
    try testing.expect(src.set(too_long)); // 바뀌었다(비워졌다)
    try testing.expect(src.isEmpty());

    _ = src.set("/ok/a.jsonl");
    try testing.expect(src.set("relative/a.jsonl"));
    try testing.expect(src.isEmpty());

    _ = src.set("/ok/a.jsonl");
    try testing.expect(src.set(""));
    try testing.expect(src.isEmpty());

    // 이미 비어 있으면 바뀐 것이 아니다.
    try testing.expect(!src.set(""));
}

fn feedInChunks(src: []const u8, chunk: usize, out: *std.ArrayList(Hit)) !StreamScanner {
    var sc: StreamScanner = .{};
    errdefer sc.deinit(testing.allocator);
    var i: usize = 0;
    while (i < src.len) {
        const end = @min(src.len, i + chunk);
        try sc.feed(testing.allocator, src[i..end], out);
        i = end;
    }
    return sc;
}

test "StreamScanner: 청크가 이미지 한가운데를 갈라도 결과가 같다 — 1바이트씩 먹여도" {
    const line =
        \\{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAABBBB"}},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"CCCC"}}]}
    ;
    const src = line ++ "\n";

    // 기준: 통째로 훑은 결과.
    var whole: std.ArrayList(Hit) = .empty;
    defer whole.deinit(testing.allocator);
    _ = try scanBuffer(testing.allocator, src, 0, &whole);
    try testing.expectEqual(@as(usize, 2), whole.items.len);

    // **1바이트씩** 먹여도 같아야 한다. 경계 처리가 틀리면 여기서 개수나 오프셋이 갈린다.
    for ([_]usize{ 1, 2, 7, 64, 4096 }) |chunk| {
        var got: std.ArrayList(Hit) = .empty;
        defer got.deinit(testing.allocator);
        var sc = try feedInChunks(src, chunk, &got);
        defer sc.deinit(testing.allocator);

        try testing.expectEqual(whole.items.len, got.items.len);
        for (whole.items, got.items) |w, g| {
            try testing.expectEqual(w.data_offset, g.data_offset);
            try testing.expectEqual(w.data_len, g.data_len);
            try testing.expectEqual(w.kind, g.kind);
            try testing.expectEqual(w.mime, g.mime);
            try testing.expectEqual(w.line_offset, g.line_offset);
        }
        // 오프셋이 **파일 절대값**인지도 함께 본다 — 청크 상대값이면 여기서 갈린다.
        try testing.expectEqualStrings("AAAABBBB", src[got.items[0].data_offset..][0..8]);
        try testing.expectEqualStrings("CCCC", src[got.items[1].data_offset..][0..4]);
        try testing.expectEqual(@as(u64, src.len), sc.consumed);
        try testing.expect(!sc.partial);
    }
}

test "StreamScanner: consumed 는 마지막 개행까지만 간다 — 잘린 꼬리는 남겨 둔다" {
    const complete =
        \\{"content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}]}
    ;
    const partial_tail = "{\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"TAIL\"}},{\"type\":\"image\"";
    const src = complete ++ "\n" ++ partial_tail;

    var got: std.ArrayList(Hit) = .empty;
    defer got.deinit(testing.allocator);
    var sc = try feedInChunks(src, 8, &got);
    defer sc.deinit(testing.allocator);

    // 완결된 줄의 하나만 센다. 꼬리의 "TAIL" 은 **완결돼 있어도** 아직 세지 않는다 —
    // 세면 다음 회차가 그 줄을 처음부터 다시 읽을 때 같은 이미지를 두 번 센다.
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqual(@as(u64, complete.len + 1), sc.consumed);
    try testing.expectEqual(partial_tail.len, sc.carry.items.len);
}

test "StreamScanner: 개행 없는 거대 꼬리는 버리고 partial 로 밝힌다" {
    var sc: StreamScanner = .{};
    defer sc.deinit(testing.allocator);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);

    const blob = try testing.allocator.alloc(u8, max_line_bytes + 1024);
    defer testing.allocator.free(blob);
    @memset(blob, 'x'); // 개행이 하나도 없다 — 손상 파일·바이너리가 이렇게 온다

    try sc.feed(testing.allocator, blob, &out);
    // 버퍼가 파일 크기만큼 자라지 않는다.
    try testing.expectEqual(@as(usize, 0), sc.carry.items.len);
    try testing.expect(sc.partial);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "StreamScanner: 이미지가 상한을 넘으면 더 담지 않고 partial 이다" {
    var sc: StreamScanner = .{};
    defer sc.deinit(testing.allocator);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);

    const one =
        \\{"content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}]}
    ;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var i: usize = 0;
    while (i < max_hits_per_file + 5) : (i += 1) {
        try src.appendSlice(testing.allocator, one);
        try src.append(testing.allocator, '\n');
    }
    try sc.feed(testing.allocator, src.items, &out);

    try testing.expectEqual(max_hits_per_file, out.items.len);
    try testing.expect(sc.partial); // 「비었다」가 아니라 「못 봤다」임을 밝힌다
}

test "2중 저장은 접는다 — 같은 줄의 tool_file 사본은 세지 않는다 (§4.3)" {
    // 실측: 3,226 장 중 1,424 장(44%)이 이 사본이었다. 접지 않으면 에이전트가 읽은 이미지가 전부 두 번 뜬다.
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    // 실제 모양: `message.content[].content[].source.data` 와 `toolUseResult.file.base64` 가 한 줄에 있고
    // **바이트가 같다**(실측 identical 1,425 / different 0).
    const line =
        \\{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}]},"toolUseResult":{"file":{"base64":"AAAA","type":"image"}}}
    ;
    try scanLine(allocator, line, 0, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(Kind.claude_image, out.items[0].kind);
    try std.testing.expectEqual(Mime.png, out.items[0].mime);
}

test "2중 저장 접기: tool_file 만 있는 줄은 그대로 남는다 — 유일본을 버리지 않는다" {
    // 실측에서는 0건이지만 provider 가 바뀌면 생길 수 있다. 그때 무조건 버리면 그 이미지가 통째로
    // 사라지고 증상은 「어떤 이미지는 안 보인다」라 원인을 못 찾는다.
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const line =
        \\{"type":"user","toolUseResult":{"file":{"base64":"BBBB","type":"image"}}}
    ;
    try scanLine(allocator, line, 0, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(Kind.claude_tool_file, out.items[0].kind);
}

test "2중 저장 접기: 앞 줄에서 찾은 것은 건드리지 않는다" {
    // 접기는 **이번 줄에서 더한 것**만 본다. 버퍼 스캔은 한 `out` 에 여러 줄을 이어 담으므로,
    // 범위를 안 나누면 앞 줄들의 결과가 통째로 잘린다.
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const first =
        \\{"content":[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"ZZZZ"}}]}
    ;
    const second =
        \\{"content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}],"toolUseResult":{"file":{"base64":"AAAA"}}}
    ;
    try scanLine(allocator, first, 0, &out);
    try scanLine(allocator, second, 200, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 앞 줄 1 + 이번 줄 1(사본 접힘)
    try std.testing.expectEqual(Mime.jpeg, out.items[0].mime);
    try std.testing.expectEqual(@as(u64, 0), out.items[0].line_offset);
    try std.testing.expectEqual(@as(u64, 200), out.items[1].line_offset);
}

test "Chain: 뒤에 잇고, 같은 경로는 두 번 담지 않는다" {
    // 부모가 자기 자신을 가리키는 기록이 오면 같은 파일을 두 번 훑어 이미지가 두 배로 뜬다.
    var c: Chain = .{};
    try testing.expect(c.isEmpty());
    try testing.expect(c.append("/a/one.jsonl"));
    try testing.expect(c.append("/a/two.jsonl"));
    try testing.expect(!c.append("/a/one.jsonl")); // 중복은 거부
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqualStrings("/a/one.jsonl", c.get(0).?);
    try testing.expectEqualStrings("/a/two.jsonl", c.get(1).?);
    try testing.expect(c.get(2) == null);
    try testing.expectEqualStrings("/a/one.jsonl", c.head());
}

test "Chain: 상한에서 멈춘다 — 1.8 GB 부모가 줄줄이 붙지 않게" {
    var c: Chain = .{};
    try testing.expect(c.append("/a/1"));
    try testing.expect(c.append("/a/2"));
    try testing.expect(c.append("/a/3"));
    try testing.expect(!c.append("/a/4")); // max_chain = 3
    try testing.expectEqual(max_chain, c.len);
    c.clear();
    try testing.expect(c.isEmpty());
    try testing.expectEqualStrings("", c.head());
}

test "Chain: 상대 경로·빈 값은 담기지 않는다 — Source 규칙을 그대로 쓴다" {
    var c: Chain = .{};
    try testing.expect(!c.append(""));
    try testing.expect(!c.append("relative/path.jsonl"));
    try testing.expect(c.isEmpty());
}

test "Hit.file_index 기본값은 0 — 스캐너는 파일 하나만 훑는다" {
    // 스캐너가 이 값을 건드리면 여러 파일을 이어 담는 호출자와 싸운다.
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const line =
        \\{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}
    ;
    try scanLine(allocator, line, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u8, 0), out.items[0].file_index);
}

test "긴 줄이 청크로 쪼개져 와도 이월 버퍼를 옮기지 않는다 — O(N²) 회귀 가드" {
    // **실측이 잡은 결함이다**(2026-08-30, 1,980 MB 실제 rollout): 개행을 못 만난 청크마다 이월
    // 버퍼 **전체**를 자기 자신에게 memcpy 했다. 긴 줄 하나가 64 KiB 청크 N 개로 쌓이는 동안
    // O(N²) 바이트를 옮긴다 — 그 한 줄을 고치니 **52.9 초 → 10.1 초** 였다.
    //
    // 시간으로 재면 기계마다 달라 불안정하다. **옮긴 횟수**로 못박는다: 개행이 오기 전에는 0 이다.
    const allocator = testing.allocator;
    var scanner: StreamScanner = .{};
    defer scanner.deinit(allocator);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);

    const chunk = "x" ** 4096;
    for (0..64) |_| try scanner.feed(allocator, chunk, &out);
    // 아직 한 줄도 안 끝났다 — 옮길 것이 없다.
    try testing.expectEqual(@as(u64, 0), scanner.carry_moves);
    try testing.expectEqual(@as(u64, 0), scanner.consumed);
    try testing.expectEqual(@as(usize, 64 * 4096), scanner.carry.items.len);

    // 개행이 오면 그때 한 번 옮긴다(꼬리만).
    try scanner.feed(allocator, "\n", &out);
    try testing.expectEqual(@as(u64, 1), scanner.carry_moves);
    try testing.expectEqual(@as(u64, 64 * 4096 + 1), scanner.consumed);
    try testing.expectEqual(@as(usize, 0), scanner.carry.items.len);
}

test "청크가 줄 여럿을 담아도 이미지를 찾고 오프셋이 파일 절대다" {
    // 위 가드가 「안 옮긴다」만 보므로, **옮기는 쪽이 여전히 맞는지**도 같이 본다 —
    // 최적화가 정확성을 깨는 자리가 정확히 여기다.
    const allocator = testing.allocator;
    var scanner: StreamScanner = .{};
    defer scanner.deinit(allocator);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);

    const filler = "{\"type\":\"user\",\"message\":{\"content\":[]}}\n";
    const img =
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"," ++
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}}]}}\n";
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    try doc.appendSlice(allocator, filler);
    const img_at = doc.items.len;
    try doc.appendSlice(allocator, img);
    try doc.appendSlice(allocator, filler);

    // 한 바이트씩 먹여도(가장 잔인한 쪼개기) 결과가 같아야 한다.
    for (doc.items) |b| try scanner.feed(allocator, &.{b}, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, img_at), out.items[0].line_offset);
    try testing.expectEqualStrings(
        "QUJD",
        doc.items[out.items[0].data_offset..][0..out.items[0].data_len],
    );
}

test "compacted 창: 경계 안팎을 정확히 가른다 — 성능 때문에 조용히 놓치지 않는다" {
    // **창 제한은 성능 최적화이고, 최적화가 결과를 바꾸면 안 된다**(적대적 검증 2026-08-30).
    // 실측 428 파일 / 14,206 줄에서 마커 위치는 중앙 40 · **최대 55** 였고, 창 512 B 가 놓친 것은 0 이다.
    // 여기서는 코퍼스에 **없는** 경계를 직접 만들어 가른다.
    const allocator = testing.allocator;
    const img = "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,QUJD\"}";

    // ① 마커가 창 **안**이면 그 줄은 통째로 건너뛴다.
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, "{\"pad\":\"");
        try line.appendNTimes(allocator, 'x', compacted_search_window - 64);
        try line.appendSlice(allocator, "\",\"type\":\"compacted\",\"c\":[");
        try line.appendSlice(allocator, img);
        try line.appendSlice(allocator, "]}\n");
        var out: std.ArrayList(Hit) = .empty;
        defer out.deinit(allocator);
        _ = try scanBuffer(allocator, line.items, 0, &out);
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }

    // ② 마커가 창 **밖**이면 못 잡는다 — **알려진 한계**다(그래서 창을 실측 최대의 9.3 배로 둔다).
    //    이 단언은 「창이 실제로 제한으로 작동한다」를 못박는다.
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, "{\"pad\":\"");
        try line.appendNTimes(allocator, 'x', compacted_search_window + 64);
        try line.appendSlice(allocator, "\",\"type\":\"compacted\",\"c\":[");
        try line.appendSlice(allocator, img);
        try line.appendSlice(allocator, "]}\n");
        var out: std.ArrayList(Hit) = .empty;
        defer out.deinit(allocator);
        _ = try scanBuffer(allocator, line.items, 0, &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
    }

    // ③ 창이 실측 최대(55)를 넉넉히 덮는다 — 이 부등식이 깨지면 실데이터를 놓치기 시작한다.
    try testing.expect(compacted_search_window >= 512);
}

test "compacted 판정이 청크 경계에 쪼개져도 같다" {
    // 스트리밍은 줄을 모아 판정하므로 청크 경계와 무관해야 한다. 최적화가 그 불변식을 깨는지 본다.
    const allocator = testing.allocator;
    const doc =
        "{\"timestamp\":\"x\",\"type\":\"compacted\",\"c\":[{\"type\":\"input_image\"," ++
        "\"image_url\":\"data:image/png;base64,QUJD\"}]}\n" ++
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"," ++
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"WFla\"}}]}}\n";

    for ([_]usize{ 1, 3, 17, 64, 4096 }) |step| {
        var scanner: StreamScanner = .{};
        defer scanner.deinit(allocator);
        var out: std.ArrayList(Hit) = .empty;
        defer out.deinit(allocator);
        var i: usize = 0;
        while (i < doc.len) : (i += step) {
            try scanner.feed(allocator, doc[i..@min(doc.len, i + step)], &out);
        }
        // compacted 줄의 이미지는 안 세고, 그 다음 줄의 것만 센다.
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqualStrings(
            "WFla",
            doc[out.items[0].data_offset..][0..out.items[0].data_len],
        );
    }
}

test "쓰는 도중에 읽어도 반쪽 이미지를 만들지 않는다 — 자동 갱신이 새로 만든 상황" {
    // 자동 갱신(IG2)이 붙은 뒤로 스캔은 **에이전트가 쓰는 도중에** 돈다. 한 바이트씩 자라는 파일을
    // 매 단계 처음부터 다시 훑으며, 나온 히트가 언제나 **완성된 줄** 안에 있는지 본다.
    const allocator = testing.allocator;
    const doc =
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"," ++
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJDREVG\"}}]}}\n" ++
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"," ++
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"WFlaWFla\"}}]}}\n";

    var grown: usize = 1;
    while (grown <= doc.len) : (grown += 1) {
        const seen = doc[0..grown];
        // **제품 경로로 읽는다.** 처음에는 `scanBuffer`(전량 스캔 헬퍼)를 썼는데, 제품은
        // `StreamScanner.feed` 로 읽는다 — 뮤테이션이 그것을 짚어 줬다: `feed` 를 망가뜨렸는데
        // 이 test 가 통과했다. **테스트가 제품이 안 쓰는 길을 지키고 있었다.**
        var out: std.ArrayList(Hit) = .empty;
        defer out.deinit(allocator);
        var scanner: StreamScanner = .{};
        defer scanner.deinit(allocator);
        var fed: usize = 0;
        while (fed < seen.len) : (fed += 13) {
            try scanner.feed(allocator, seen[fed..@min(seen.len, fed + 13)], &out);
        }

        // 지금까지 **완성된** 줄(마지막 개행까지)의 길이.
        const complete = if (std.mem.lastIndexOfScalar(u8, seen, '\n')) |nl| nl + 1 else 0;
        for (out.items) |hit| {
            // ① 히트는 완성된 줄 안에서만 나온다 — 반쪽 줄을 인덱싱하지 않는다.
            try testing.expect(hit.data_offset + hit.data_len <= complete);
            // ② payload 가 온전하다: 뒤에 닫는 따옴표가 있다.
            try testing.expect(hit.data_offset + hit.data_len < seen.len);
            try testing.expectEqual(@as(u8, '"'), seen[hit.data_offset + hit.data_len]);
        }
        // ③ 완성된 줄 수만큼만 나온다.
        const want: usize = if (complete >= doc.len) 2 else if (complete > 0) 1 else 0;
        try testing.expectEqual(want, out.items.len);
    }
}

test "쓰는 도중에 읽어도 스트리밍이 같은 답을 낸다 — 청크 경계와 무관" {
    // 위 test 는 「매번 처음부터」다. 제품은 청크로 먹이므로 그쪽도 같은 답을 내야 한다.
    // 자동 갱신은 파일이 자랄 때마다 **새 스캐너**로 처음부터 훑으므로 둘이 어긋나면 안 된다.
    const allocator = testing.allocator;
    const doc =
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"," ++
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJDREVG\"}}]}}\n";

    var grown: usize = 1;
    while (grown <= doc.len) : (grown += 1) {
        const seen = doc[0..grown];

        var whole: std.ArrayList(Hit) = .empty;
        defer whole.deinit(allocator);
        _ = try scanBuffer(allocator, seen, 0, &whole);

        var streamed: std.ArrayList(Hit) = .empty;
        defer streamed.deinit(allocator);
        var scanner: StreamScanner = .{};
        defer scanner.deinit(allocator);
        var i: usize = 0;
        while (i < seen.len) : (i += 7) {
            try scanner.feed(allocator, seen[i..@min(seen.len, i + 7)], &streamed);
        }

        try testing.expectEqual(whole.items.len, streamed.items.len);
        for (whole.items, streamed.items) |a, b| {
            try testing.expectEqual(a.data_offset, b.data_offset);
            try testing.expectEqual(a.data_len, b.data_len);
        }
    }
}

test "순번: 같은 줄에 붙은 세 장은 적힌 순서로 1/3·2/3·3/3" {
    const hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 100, .data_offset = 300, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 100, .data_offset = 400, .data_len = 4, .kind = .claude_image, .mime = .png },
    };
    for (0..3) |i| {
        const s = sequenceAt(&hits, i);
        try std.testing.expectEqual(@as(u16, @intCast(i + 1)), s.index);
        try std.testing.expectEqual(@as(u16, 3), s.total);
    }
}

test "순번: 목록을 뒤집어도 적힌 순서를 말한다" {
    // 갤러리는 최신을 먼저 보이려고 전체를 뒤집는다. 그때 순번까지 뒤집히면 「3/3」이 첫 장에 붙는다.
    var hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 100, .data_offset = 300, .data_len = 4, .kind = .claude_image, .mime = .png },
    };
    std.mem.reverse(Hit, &hits);
    try std.testing.expectEqual(@as(u16, 2), sequenceAt(&hits, 0).index); // 뒤집혀 앞에 온 것이 둘째 장
    try std.testing.expectEqual(@as(u16, 1), sequenceAt(&hits, 1).index);
}

test "순번: 한 장뿐이면 0 — 「1/1」은 알려 주는 것이 없다" {
    const hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 900, .data_offset = 950, .data_len = 4, .kind = .claude_image, .mime = .png },
    };
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 0));
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 1));
}

test "순번: 다른 줄과 섞이지 않는다" {
    const hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 100, .data_offset = 300, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 800, .data_offset = 900, .data_len = 4, .kind = .claude_image, .mime = .png },
    };
    try std.testing.expectEqual(@as(u16, 2), sequenceAt(&hits, 1).total);
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 2));
}

test "순번: 파일이 다르면 오프셋이 같아도 남남이다" {
    // 재개 세션은 부모 파일까지 이어 담는다(§3.3). 그때 오프셋만 보면 다른 파일의 이미지가 한 묶음이 된다.
    const hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png, .file_index = 0 },
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png, .file_index = 1 },
    };
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 0));
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 1));
}

test "순번: 묶음이 상한을 넘으면 세지 않는다" {
    var hits: [max_seq_group + 1]Hit = undefined;
    for (&hits, 0..) |*h, i| h.* = .{
        .line_offset = 100,
        .data_offset = 200 + @as(u64, i) * 10,
        .data_len = 4,
        .kind = .claude_image,
        .mime = .png,
    };
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 0));
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, hits.len - 1));
}

test "순번: 범위 밖 인덱스는 빈 값 — 부르는 쪽이 길이를 어긋내도 죽지 않는다" {
    const hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png },
    };
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 1));
    try std.testing.expectEqual(Seq{}, sequenceAt(&.{}, 0));
}

test "실제 모양의 다중 첨부: 두 장이 같은 라벨을 받고 순번으로만 갈린다" {
    // **이 테스트가 이 기능의 이유다.** 실측(2026-09-05, Claude 트랜스크립트 131 파일)에서 사용자
    // 다중 첨부 13 줄이 **전부** 텍스트 블록 하나뿐이고 그 텍스트가 첫 이미지보다 앞이었다. 그래서
    // 두 장은 글자 그대로 같은 설명을 받고, 시각까지 같다(한 레코드다) — 순번 말고는 가를 것이 없다.
    const context = @import("agent_image_context.zig");
    const allocator = std.testing.allocator;

    const line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"이 두 화면 비교해 주세요\"}," ++
        "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"AAAA\"}}," ++
        "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"BBBB\"}}" ++
        "]}}\n";

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(allocator);
    _ = try scanBuffer(allocator, line, 0, &hits);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);

    for (hits.items, 0..) |h, i| {
        // 라벨은 payload **앞** 조각만 본다 — 스캔 백엔드가 파일에서 떼어 주는 것과 같은 구간이다.
        const prefix = line[@intCast(h.line_offset)..@intCast(h.data_offset)];
        const label = context.label(prefix, "");
        try std.testing.expectEqualStrings("이 두 화면 비교해 주세요", label.text());
        try std.testing.expectEqual(context.Source.message_text, label.source);

        const seq = sequenceAt(hits.items, i);
        try std.testing.expectEqual(@as(u16, @intCast(i + 1)), seq.index);
        try std.testing.expectEqual(@as(u16, 2), seq.total);
    }

    // 접두까지 태워 「무엇이 화면에 뜨는가」를 못 박는다 — 두 줄이 순번으로만 갈린다.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("첨부 1/2", context.originPrefix(&buf, "첨부", sequenceAt(hits.items, 0).index, 2));
    try std.testing.expectEqualStrings("첨부 2/2", context.originPrefix(&buf, "첨부", sequenceAt(hits.items, 1).index, 2));
}

test "실제 모양의 도구 읽기: 2중 저장을 접고도 출처가 「에이전트가 읽음」이다" {
    // 에이전트가 읽은 이미지는 한 줄에 마커가 둘이지만(§4.3 의 2 중 저장) 실제로는 **한 장**이다.
    // 여기서 순번이 붙으면 「1/2」라는 거짓말이 화면에 뜬다 — 접기와 순번이 같은 줄에서 만나는 자리다.
    const context = @import("agent_image_context.zig");
    const allocator = std.testing.allocator;

    const prev = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_01\"," ++
        "\"name\":\"Read\",\"input\":{\"file_path\":\"/tmp/dock-layout.png\"}}]}}";
    const line = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_01\"," ++
        "\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"AAAA\"}}]}}," ++
        "\"toolUseResult\":{\"file\":{\"base64\":\"AAAA\",\"type\":\"image\"}}}\n";

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(allocator);
    _ = try scanBuffer(allocator, line, 0, &hits);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len); // 사본은 접혔다
    try std.testing.expectEqual(Seq{}, sequenceAt(hits.items, 0)); // 한 장이니 순번 없음

    const prefix = line[@intCast(hits.items[0].line_offset)..@intCast(hits.items[0].data_offset)];
    const label = context.label(prefix, prev);
    try std.testing.expectEqualStrings("dock-layout.png", label.text());
    try std.testing.expectEqual(context.Source.tool_file_path, label.source);
}

// ── 활동(도구 호출) 스캔 — 계약 `docs/agent-activity-view.md` §3.1 ─────────────────────────────
//
// **구조는 실측, 값은 합성**이다(계약 §5: 트랜스크립트 내용을 fixture 에 쓰지 않는다). 아래 레코드
// 모양은 이 맥의 실제 파일에서 읽은 것이고, 그 안의 경로·명령·설명만 지어낸 것이다.

fn activityAt(hits: *const std.ArrayList(Hit), i: usize, line: []const u8) []const u8 {
    const h = hits.items[i];
    const start: usize = @intCast(h.data_offset);
    return line[start .. start + h.data_len];
}

fn toolNameAt(hits: *const std.ArrayList(Hit), i: usize, line: []const u8) []const u8 {
    const h = hits.items[i];
    return line[h.name_rel .. h.name_rel + h.name_len];
}

test "활동: Claude 도구 호출은 description 을 대상으로 잡는다" {
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01AB","name":"Bash","input":{"command":"grep -rn foo src/","description":"foo 쓰는 자리 찾기"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Kind.claude_tool_use, hits.items[0].kind);
    try testing.expectEqual(Activity.exec, hits.items[0].activity);
    try testing.expect(!hits.items[0].kind.isImage());
    // **명령이 아니라 설명이다** — 실측이 정한 순서다(§2.2).
    try testing.expectEqualStrings("foo 쓰는 자리 찾기", activityAt(&hits, 0, line));
    try testing.expectEqualStrings("Bash", toolNameAt(&hits, 0, line));
}

test "활동: Read 는 description 이 없어 file_path 가 대상이다" {
    // 실측: `Read` 의 description 은 0 / 635 다.
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01CD","name":"Read","input":{"file_path":"/tmp/shots/dock.png"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Activity.read, hits.items[0].activity);
    try testing.expectEqualStrings("/tmp/shots/dock.png", activityAt(&hits, 0, line));
}

test "활동: 설명도 경로도 없으면 명령이 대상이다" {
    // 실측: Bash 의 31.2% 에는 description 이 없다.
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01EF","name":"Bash","input":{"command":"zig build test"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqualStrings("zig build test", activityAt(&hits, 0, line));
}

test "활동: 셋 다 없으면 도구 이름이 대상이다 — 빈 줄을 남기지 않는다" {
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01GH","name":"ListAgents","input":{}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Activity.other, hits.items[0].activity);
    try testing.expectEqualStrings("ListAgents", activityAt(&hits, 0, line));
}

test "활동: 명령 안의 이스케이프된 따옴표에서 잘리지 않는다" {
    // base64 와 갈리는 지점이다 — 이미지 payload 에는 이스케이프가 없어 다음 `"` 가 곧 끝이지만
    // 사람이 쓴 명령에는 `\"` 가 흔하다. `indexOfScalar` 로 끊으면 `grep -n ` 에서 잘린다.
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01IJ","name":"Bash","input":{"command":"grep -n \"pub fn main\" src/main.zig && echo done"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqualStrings(
        \\grep -n \"pub fn main\" src/main.zig && echo done
    , activityAt(&hits, 0, line));
}

test "활동: 여러 줄 명령도 통째로 잡는다" {
    // 실측: 명령의 52.4% 가 여러 줄이다. `\n` 은 JSON 이스케이프라 값 안에 있다.
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01KL","name":"Bash","input":{"command":"cd /tmp\npython3 - <<'PY'\nprint(1)\nPY"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expect(std.mem.indexOf(u8, activityAt(&hits, 0, line), "PY") != null);
}

test "활동: description 이 긴 명령 뒤에 있어도 찾는다 — 창을 두지 않는 이유" {
    // 실측: 대상 문자열 최대 23,866 B. 512 바이트 창(`key_search_window`)이면 못 본다.
    // 한 줄에 호출이 하나뿐이라(실측 39,618/39,618) 줄 전체를 봐도 남의 값을 집지 않는다.
    const head =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01MN","name":"Bash","input":{"command":"
    ;
    const tail =
        \\","description":"긴 명령 뒤의 설명"}}]}}
    ;
    var long: [4096]u8 = undefined;
    @memset(&long, 'x');
    const line = try std.mem.concat(testing.allocator, u8, &.{ head, &long, tail });
    defer testing.allocator.free(line);
    const text = try std.mem.concat(testing.allocator, u8, &.{ line, "\n" });
    defer testing.allocator.free(text);

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(testing.allocator);
    _ = try scanBuffer(testing.allocator, text, 0, &hits);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqualStrings("긴 명령 뒤의 설명", activityAt(&hits, 0, line));
}

test "활동: 축은 도구 이름으로만 가른다 — MCP 와 편집은 other 다" {
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01OP","name":"mcp__drive__search","input":{"query":"설계"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Activity.other, hits.items[0].activity);
    try testing.expectEqualStrings("mcp__drive__search", toolNameAt(&hits, 0, line));
    // 대상 키가 없으므로 이름이 대상이다 — MCP 인자 이름을 지어내지 않는다.
    try testing.expectEqualStrings("mcp__drive__search", activityAt(&hits, 0, line));
}

test "활동: grep 은 읽기가 아니라 실행이다 — 명령의 의미를 판정하지 않는다" {
    // 계약 §2.3. 이 판정자는 「그렇게 되면 좋겠다」가 아니라 **그렇게 하기로 한 결정**을 지킨다.
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01QR","name":"Bash","input":{"command":"sed -n '1,20p' README.md"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(Activity.exec, hits.items[0].activity);
}

test "활동: Codex custom_tool_call 은 input 이 대상이고 결과 레코드에는 안 걸린다" {
    const call =
        \\{"timestamp":"2026-09-07T00:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_AB","name":"exec","input":"sed -n '1,20p' src/main.zig","status":"completed"}}
    ;
    const output =
        \\{"timestamp":"2026-09-07T00:00:01Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_AB","output":"[{\"type\":\"input_text\",\"text\":\"done\"}]"}}
    ;
    var hits = try collect(call ++ "\n" ++ output ++ "\n");
    defer hits.deinit(testing.allocator);

    // **결과 줄은 활동이 아니다** — 마커가 닫는 따옴표까지라 `custom_tool_call_output` 에 안 걸린다.
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Kind.codex_tool_call, hits.items[0].kind);
    try testing.expectEqual(Activity.exec, hits.items[0].activity);
    try testing.expectEqualStrings("sed -n '1,20p' src/main.zig", activityAt(&hits, 0, call));
}

test "활동: 상한은 종류별이다 — 활동이 넘쳐도 이미지가 밀려나지 않는다" {
    // **한 통으로 세면 갤러리가 조용히 빈다.** 활동은 세션당 최대 12,200개인데 이미지 상한은 4,096
    // 이라, 상한을 공유하면 활동이 많은 세션에서 이미지가 인덱스에 못 들어간다. 사용자에게는
    // 「이미지가 없습니다」로 보이고 그것은 고장과 구분되지 않는다.
    const call =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"echo hi"}}]}}
    ;
    const image =
        \\{"type":"user","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}
    ;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    // 이미지 상한을 **넘기고도 남게** 활동을 쌓는다.
    var i: usize = 0;
    while (i < max_hits_per_file + 64) : (i += 1) {
        try text.appendSlice(testing.allocator, call);
        try text.append(testing.allocator, '\n');
    }
    // 그 **뒤에** 이미지를 둔다 — 상한을 공유하면 이 줄이 잘린다.
    try text.appendSlice(testing.allocator, image);
    try text.append(testing.allocator, '\n');

    var scanner: StreamScanner = .{};
    defer scanner.deinit(testing.allocator);
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(testing.allocator);
    try scanner.feed(testing.allocator, text.items, &hits);

    var images: usize = 0;
    var activities: usize = 0;
    for (hits.items) |h| {
        if (h.kind.isImage()) images += 1 else activities += 1;
    }
    // **뒤에 온 이미지가 살아 있다.**
    try testing.expectEqual(@as(usize, 1), images);
    try testing.expectEqual(max_hits_per_file + 64, activities);
    try testing.expect(!scanner.partial); // 둘 다 자기 상한 안이라 자른 것이 없다
}

test "활동: 상한을 넘으면 **오래된 쪽**을 버린다 — 최신이 남는다 (적대적 O4)" {
    // **이 뷰의 물음은 「아까 그 명령 뭐였지」다.** 앞에서 채우고 넘치면 버리면 그 물음의 정반대를
    // 답한다 — 갤러리가 IG7 에서 똑같이 겪었다. 실측 최악 세션은 활동이 상한의 **11.1 배**
    // (181,907 건)라, 무엇을 남기느냐가 곧 기능의 쓸모다.
    const line_head =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Bash","input":{"description":"
    ;
    const line_tail =
        \\"}}]}}
    ;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    // 상한을 넘기고도 남게 쌓는다. 설명에 **번호**를 넣어 어느 것이 남았는지 본다.
    const total = max_activity_hits_per_file + 1000;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        try text.appendSlice(testing.allocator, line_head);
        var num_buf: [16]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable;
        try text.appendSlice(testing.allocator, num);
        try text.appendSlice(testing.allocator, line_tail);
        try text.append(testing.allocator, '\n');
    }

    var scanner: StreamScanner = .{};
    defer scanner.deinit(testing.allocator);
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(testing.allocator);
    try scanner.feed(testing.allocator, text.items, &hits);

    // 상한 안이고, 잘렸다는 사실을 **종류까지** 밝힌다.
    try testing.expect(hits.items.len <= max_activity_hits_per_file);
    // **너무 많이 버리지 않는다.** 퇴출은 1/8 씩이므로 항목은 상한의 7/8 아래로 안 내려간다 —
    // 절반씩 버리던 때는 최악에 상한의 절반만 남았다(사용자 지적 2026-09-07).
    try testing.expect(hits.items.len >= max_activity_hits_per_file / 8 * 7);
    try testing.expect(scanner.activity_partial);
    try testing.expect(!scanner.image_partial); // 이미지는 애초에 없었다 — 종류를 섞지 않는다

    // **마지막 줄이 남아 있다.** 앞에서 채우고 버리는 방식이면 여기서 깨진다.
    const last = hits.items[hits.items.len - 1];
    const start: usize = @intCast(last.data_offset);
    const label = text.items[start .. start + last.data_len];
    var want_buf: [16]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf, "{d}", .{total - 1}) catch unreachable;
    try testing.expectEqualStrings(want, label);

    // 그리고 **첫 줄은 버려졌다**(그것이 「오래된 쪽을 버린다」의 뜻이다).
    const first = hits.items[0];
    const fstart: usize = @intCast(first.data_offset);
    const first_label = text.items[fstart .. fstart + first.data_len];
    try testing.expect(!std.mem.eql(u8, first_label, "0"));
}

test "접기: 퇴출이 주인을 버리면 접기도 풀린다 — 이미지가 「전체」에서 사라지지 않게 (§2.2.1 적대적)" {
    // ⚠️ **접기는 자리(인덱스)로 매어 있다.** 퇴출은 `out` 을 제자리 압축하므로 그 자리를 전부
    // 무효화한다 — 대기 링이 같은 이유로 `remapPendingAfterEvict` 를 갖는다. 접기를 안 맞추면
    // 결과가 더 나쁘다: 주인이 버려진 이미지가 **접힌 채 남아 「전체」에서 통째로 사라진다.**
    //
    // 실측 최악 세션은 활동이 상한의 11.1 배라 이 길은 상상이 아니다.
    const allocator = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    const call_head =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_
    ;
    const call_tail =
        \\","name":"Bash","input":{"description":"x"}}]}}
    ;
    // 이미지 결과 하나 — 실측 키 순서(`tool_use_id` → `type` → `content`)를 따른다.
    const img_head =
        \\{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_
    ;
    const img_tail =
        \\","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"AAAABBBB","media_type":"image/png"}}]}]}}
    ;

    // 이른 것 하나(반드시 버려진다) · 늦은 것 하나(반드시 남는다).
    const early_id = "E";
    const late_id = "L";
    const total = max_activity_hits_per_file + max_activity_hits_per_file / 4;

    var i: usize = 0;
    while (i < total) : (i += 1) {
        var buf: [24]u8 = undefined;
        const id = if (i == 0)
            early_id
        else if (i == total - 1)
            late_id
        else
            std.fmt.bufPrint(&buf, "n{d}", .{i}) catch unreachable;
        try text.appendSlice(allocator, call_head);
        try text.appendSlice(allocator, id);
        try text.appendSlice(allocator, call_tail);
        try text.append(allocator, '\n');
        // 그 호출의 결과가 곧바로 이미지인 경우는 처음과 끝뿐이다.
        if (i == 0 or i == total - 1) {
            try text.appendSlice(allocator, img_head);
            try text.appendSlice(allocator, id);
            try text.appendSlice(allocator, img_tail);
            try text.append(allocator, '\n');
        }
    }

    var scanner: StreamScanner = .{};
    defer scanner.deinit(allocator);
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(allocator);
    try scanner.feed(allocator, text.items, &hits);
    try testing.expect(scanner.activity_partial); // 실제로 퇴출이 돌았다

    // 이미지는 **둘 다 살아 있다** — 퇴출은 활동만 버린다.
    var images: usize = 0;
    var folded: usize = 0;
    var loose: usize = 0;
    for (hits.items) |h| {
        if (!h.kind.isImage()) continue;
        images += 1;
        if (h.fold_owner == no_fold) {
            loose += 1;
            continue;
        }
        folded += 1;
        // ① **가리키는 자리가 배열 안이고, 그것이 활동이다.** 어긋나면 남의 줄로 접힌다.
        try testing.expect(h.fold_owner < hits.items.len);
        try testing.expect(!hits.items[h.fold_owner].kind.isImage());
        // ② 그리고 그 호출은 **결과가 이미지라고 알고 있다** — 양쪽이 같은 사실을 말한다.
        try testing.expect(hits.items[h.fold_owner].result.image);
    }
    try testing.expectEqual(@as(usize, 2), images);
    // ③ 주인이 버려진 쪽은 **접기가 풀렸다**(그래야 「전체」에 제 줄로 선다).
    try testing.expectEqual(@as(usize, 1), loose);
    // ④ 살아남은 쪽은 **여전히 접혀 있다**(접기를 통째로 포기하지 않았다).
    try testing.expectEqual(@as(usize, 1), folded);
}

test "파일 번호: 퇴출이 배열을 당겨도 어긋나지 않는다 — 스캐너가 찍는다" {
    // ⚠️ **사후에 찍으면 어긋난다.** 예전 백엔드는 파일마다 `hits.items.len` 을 잡아 두고 스캔이
    // 끝난 뒤 그 **뒤쪽**에 번호를 찍었다. 그런데 퇴출은 배열을 제자리 압축하므로, 앞 파일 항목이
    // 버려지면 이 파일의 앞부분이 그 자리 **밖**으로 밀려 번호를 못 받는다(기본값 0 = 첫 파일).
    // 그러면 라벨·펼침·디코드가 **엉뚱한 파일**의 바이트를 읽는다.
    //
    // 실측 프로브: 앞 파일 51 개 중 **50 개가 버려지자** 이 파일의 앞 **50 개**가 0 으로 남았다.
    // 조건(다중 파일 체인 + 한 파일이 활동 상한 초과)은 둘 다 실측에 있다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);

    const head =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Bash","input":{"description":"
    ;
    const tail =
        \\"}}]}}
    ;

    // 퇴출은 한 번에 `activity_count / 8` 을 버린다. 그보다 넉넉히 넣어야 앞 파일 항목이 남는다.
    const prev_activities: usize = max_activity_hits_per_file / 2;

    // ── 파일 0: 활동 여럿 + 이미지 1. 활동은 퇴출의 첫 먹잇감이다.
    {
        var t0: std.ArrayList(u8) = .empty;
        defer t0.deinit(allocator);
        // ⚠️ **앞 파일 활동을 퇴출이 다 못 먹을 만큼 넣는다.** 50 개만 두면 첫 퇴출에 전부 사라져
        // 「앞 파일 항목이 제 번호를 지키는가」가 **표본 0 으로 안 재진다** — 적대적 2 회차에서
        // 스탬프를 상수로 바꾼 뮤테이션이 이미지 단언에만 걸리고 이 축에는 안 걸리는 것으로
        // 드러났다. 이미지가 없는 체인(Codex 가 대개 그렇다)에서는 그때 아무도 안 잡는다.
        var k: usize = 0;
        while (k < prev_activities) : (k += 1) {
            try t0.appendSlice(allocator, head);
            try t0.appendSlice(allocator, "prev");
            try t0.appendSlice(allocator, tail);
            try t0.append(allocator, '\n');
        }
        try t0.appendSlice(allocator,
            \\{"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","data":"AAAA","media_type":"image/png"}}]}}
        );
        try t0.append(allocator, '\n');
        var s0: StreamScanner = .{ .file_index = 0 };
        defer s0.deinit(allocator);
        try s0.feed(allocator, t0.items, &out);
    }

    // ── 파일 1: 퇴출이 돌 만큼 쏟는다. 백엔드는 여기서 스캐너를 새로 세운다.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var i: usize = 0;
    while (i < max_activity_hits_per_file + 100) : (i += 1) {
        try text.appendSlice(allocator, head);
        try text.appendSlice(allocator, "cur");
        try text.appendSlice(allocator, tail);
        try text.append(allocator, '\n');
    }
    var s1: StreamScanner = .{ .file_index = 1 };
    defer s1.deinit(allocator);
    try s1.feed(allocator, text.items, &out);
    try testing.expect(s1.activity_partial); // 실제로 퇴출이 돌았다

    // **번호가 값을 따라간다.** 라벨이 "cur" 인 활동은 전부 파일 1, "prev" 는 전부 파일 0 이다.
    var cur_wrong: usize = 0;
    var prev_wrong: usize = 0;
    var cur_total: usize = 0;
    var prev_total: usize = 0;
    for (out.items) |h| {
        if (h.kind.isImage()) {
            // 파일 0 의 이미지는 퇴출 대상이 아니라 살아 있고, 번호도 0 이어야 한다.
            try testing.expectEqual(@as(u8, 0), h.file_index);
            continue;
        }
        const st: usize = @intCast(h.data_offset);
        const src = if (h.file_index == 0) text.items else text.items; // 어느 쪽이든 길이만 본다
        _ = src;
        _ = st;
        if (h.data_len == 3) { // "cur"
            cur_total += 1;
            if (h.file_index != 1) cur_wrong += 1;
        } else if (h.data_len == 4) { // "prev"
            prev_total += 1;
            if (h.file_index != 0) prev_wrong += 1;
        }
    }
    try testing.expect(cur_total > 0);
    try testing.expectEqual(@as(usize, 0), cur_wrong); // ← 사후 스탬프면 여기가 어긋난다
    // **앞 파일 활동이 실제로 살아남았는가를 먼저 확인한다.** 표본이 0 이면 아래 단언은 아무것도
    // 재지 않는다 — 「단언이 있다」와 「그 단언이 무언가를 본다」는 다른 사실이다.
    try testing.expect(prev_total > 0);
    try testing.expectEqual(@as(usize, 0), prev_wrong);
}

test "접기: 접힌 그림의 파일 번호는 이미 찍힌 값이다 (AV5 적대적 2회차)" {
    // ⚠️ **두 슬라이스가 순서로 묶여 있다.** 파일 번호는 `admit` 이 찍고(#3380), 접기는
    // `linkResult` 가 그 값을 **복사**한다(AV5). `feed` 안에서 `admit` 이 먼저 돌기 때문에
    // 맞는 값이 복사되는데, 그 순서가 뒤집히면 **`image_file` 이 0 으로 남아** 다중 파일 체인에서
    // 디코드가 **첫 파일**의 엉뚱한 바이트를 읽는다 — 증상은 「그림이 안 열린다」거나 더 나쁘게
    // 「남의 그림이 뜬다」이고, 원인은 화면에 안 보인다.
    //
    // 그 결합을 여기서 못박는다. 두 파일을 서로 다른 번호로 훑어 **0 이 아닌 값**이 복사되는지 본다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);

    const doc =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_P1","name":"Read","input":{"file_path":"/tmp/a.png"}}]}}
        \\{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_P1","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"AAAABBBB","media_type":"image/png"}}]}]}}
        \\
    ;

    // 파일 0 — 아무것도 안 담는다(자리만 만든다). 실제 백엔드도 파일마다 스캐너를 새로 세운다.
    {
        var s0: StreamScanner = .{ .file_index = 0 };
        defer s0.deinit(allocator);
        try s0.feed(allocator,
            \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_Z","name":"Bash","input":{"description":"x"}}]}}
        ++ "\n", &out);
    }
    // 파일 **2** — 0 도 1 도 아닌 값이라 「안 찍혔다」와 「1 로 굳었다」를 둘 다 가른다.
    var s2: StreamScanner = .{ .file_index = 2 };
    defer s2.deinit(allocator);
    try s2.feed(allocator, doc, &out);

    var call: ?Hit = null;
    var image: ?Hit = null;
    for (out.items) |h| {
        if (h.kind.isImage()) image = h else if (h.result.image) call = h;
    }
    try testing.expect(call != null);
    try testing.expect(image != null);

    // ① 그림 자신이 파일 2 다(#3380 의 스탬프).
    try testing.expectEqual(@as(u8, 2), image.?.file_index);
    // ② **그리고 호출이 든 값도 파일 2 다**(AV5 의 복사). 여기가 0 이면 디코드가 첫 파일을 읽는다.
    try testing.expectEqual(@as(u8, 2), call.?.result.image_file);
    // ③ 자리도 그림의 것이지 명령문의 것이 아니다.
    try testing.expectEqual(image.?.data_offset, call.?.result.image_offset);
    try testing.expectEqual(image.?.data_len, call.?.result.image_len);
    try testing.expect(call.?.result.image_offset != call.?.data_offset);
}

test "활동: Codex 호출 마커는 결과 레코드에 걸리지 않는다 — 방어를 직접 시험한다" {
    // **위 판정자만으로는 부족했다.** 뮤테이션으로 마커에서 닫는 따옴표를 빼도 그 판정자가 통과했다 —
    // 실제로 막고 있던 것은 마커가 아니라 「결과 레코드에 `name` 이 없다」는 성질이었기 때문이다
    // (실측 3,966 / 3,966 이 `call_id,id,…,output,type`). 즉 그 판정자는 **마커를 검증하지 않는다.**
    //
    // 방어가 둘이면 각각 시험해야 한다. 여기서는 마커 자신을 본다 — provider 가 나중에 결과
    // 레코드에 `name` 을 넣으면 그때부터는 이것이 유일한 방어다.
    try testing.expect(std.mem.indexOf(
        u8,
        "\"type\":\"custom_tool_call_output\"",
        codex_custom_tool_call_marker,
    ) == null);
    try testing.expect(std.mem.indexOf(
        u8,
        "\"type\":\"function_call_output\"",
        codex_function_call_marker,
    ) == null);
    // 반대쪽도 못박는다 — 마커가 진짜 호출 레코드에는 걸려야 한다.
    try testing.expect(std.mem.indexOf(
        u8,
        "\"type\":\"custom_tool_call\",\"call_id\":\"call_AB\"",
        codex_custom_tool_call_marker,
    ) != null);
}

test "활동: Codex compacted 줄은 활동도 건너뛴다" {
    // 이미지와 같은 이유다 — compacted 는 이전 대화를 통째로 재수록하므로 세면 몇 배가 된다.
    const line =
        \\{"type":"compacted","payload":{"type":"custom_tool_call","call_id":"call_CD","name":"exec","input":"echo hi"}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "활동: 이미지 줄과 활동 줄은 서로를 오염시키지 않는다" {
    const call =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01ST","name":"Read","input":{"file_path":"/tmp/a.png"}}]}}
    ;
    const result =
        \\{"type":"user","message":{"content":[{"tool_use_id":"toolu_01ST","type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}]}}
    ;
    var hits = try collect(call ++ "\n" ++ result ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), hits.items.len);
    try testing.expectEqual(Kind.claude_tool_use, hits.items[0].kind);
    try testing.expectEqual(Activity.read, hits.items[0].activity);
    try testing.expectEqual(Kind.claude_image, hits.items[1].kind);
    // 이미지 쪽은 활동 축을 갖지 않는다 — 두 축이 섞이면 필터가 거짓말을 한다.
    try testing.expectEqual(Activity.none, hits.items[1].activity);
    try testing.expect(hits.items[1].kind.isImage());
}

// ── AV2 판정자 — 호출과 결과를 잇는다 (계약 §3.2) ────────────────────────────────────────────
//
// **`StreamScanner` 로 태운다.** 링크는 줄 사이의 상태이므로 `scanBuffer`(줄 단위 헬퍼)로는 재지
// 못한다 — 그리고 제품이 실제로 지나는 길도 `feed` 다.

fn scanDocForTest(allocator: std.mem.Allocator, doc: []const u8, out: *std.ArrayList(Hit)) !void {
    var scanner: StreamScanner = .{};
    defer scanner.deinit(allocator);
    try scanner.feed(allocator, doc, out);
}

test "활동 결말: Claude 결과가 바로 다음 줄이면 붙고, is_error 가 실패다 (AV2)" {
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01AB","name":"Bash","input":{"command":"ls","description":"목록"}}]}}
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_01AB","content":"a\nb\nc"}]}}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_02CD","name":"Bash","input":{"command":"false","description":"실패한다"}}]}}
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_02CD","content":"boom","is_error":true}]}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(out.items[0].result.found);
    try testing.expectEqual(@as(u32, 3), out.items[0].result.lines);
    try testing.expect(!out.items[0].result.failed);
    try testing.expect(out.items[1].result.found);
    try testing.expectEqual(@as(u32, 1), out.items[1].result.lines);
    // **우리가 판정한 것이 아니다** — provider 가 적은 `is_error` 다(계약 §2.3).
    try testing.expect(out.items[1].result.failed);
}

test "접기: 결과가 이미지인 Claude 호출은 한 줄이다 (§2.2.1)" {
    // 픽스처의 **키 순서는 실측**이다(2026-09-08, 실제 기록 542 건): 블록 안이 `tool_use_id` → `type`
    // → `content` 이고, `content` 는 이미지 블록만 든다. 그 배열에는 `"text"` 가 없어서 본문 파서가
    // 되돌아가는데, 그러면 **링크 자체가 안 서서** 그 호출은 결말이 비고 이미지가 따로 한 줄 더 뜬다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01AB","name":"Read","input":{"file_path":"/tmp/shot.png"}}]}}
        \\{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01AB","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"AAAABBBB","media_type":"image/png"}}]}]},"uuid":"u","timestamp":"2026-09-08T01:00:00.000Z"}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);

    // 호출 하나 + 이미지 하나. **이미지가 사라지는 것이 아니다** — 「이미지」 필터는 그대로 본다.
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(!out.items[0].kind.isImage());
    try testing.expect(out.items[1].kind.isImage());

    // ① 호출은 이제 **결말을 안다**(전에는 본문 파싱 실패로 링크가 안 섰다).
    try testing.expect(out.items[0].result.found);
    try testing.expect(out.items[0].result.image);
    try testing.expectEqual(@as(u32, 0), out.items[0].result.lines); // 셀 줄이 없다
    try testing.expect(!out.items[0].result.failed);

    // ② 이미지는 **그 호출로 접힌다**. 「전체」가 이 값으로 두 줄을 한 줄로 만든다.
    try testing.expectEqual(@as(u32, 0), out.items[1].fold_owner);
    // ③ 호출 자신은 접히지 않는다 — 접히는 것은 겹치는 쪽뿐이다.
    try testing.expectEqual(no_fold, out.items[0].fold_owner);
}

test "접기: Codex 이미지 결과는 텍스트도 함께 온다 — 줄 수를 지우지 않는다 (§2.2.1)" {
    // 실측(2026-09-08): Codex 의 이미지 결과는 `output` 이 `[{text}, …, {input_image}]` 다. 그래서
    // **본문이 있다** — 「이미지니까 이미지라고만 적는다」로 뭉개면 provider 가 적어 준 말을 지운다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"timestamp":"2026-09-08T01:00:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","id":"c1","call_id":"call_9","name":"view_image","input":"{\"path\":\"/tmp/a.png\"}"}}
        \\{"timestamp":"2026-09-08T01:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","id":"c2","call_id":"call_9","output":[{"type":"input_text","text":"attached image"},{"type":"input_image","image_url":"data:image/png;base64,CCCCDDDD"}]}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(!out.items[0].kind.isImage());
    try testing.expect(out.items[1].kind.isImage());

    try testing.expect(out.items[0].result.found);
    try testing.expect(out.items[0].result.image);
    // **줄 수가 살아 있다** — 본문이 있기 때문이다(Claude 쪽과 갈리는 지점).
    try testing.expect(out.items[0].result.lines > 0);
    try testing.expectEqual(@as(u32, 0), out.items[1].fold_owner);
}

test "접기: 사용자가 붙인 이미지는 안 접힌다 — 부른 호출이 없다 (§2.2.1)" {
    // 실측에서 Codex `message`(role=user) 이미지가 49 건이었다. 그것들은 **결과가 아니라 입력**이라
    // 접을 주인이 없다 — 접으면 「전체」에서 통째로 사라진다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01AB","name":"Bash","input":{"command":"ls","description":"목록"}}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","data":"EEEEFFFF","media_type":"image/png"}}]}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(out.items[1].kind.isImage());
    try testing.expectEqual(no_fold, out.items[1].fold_owner);
    // 그 호출은 결말을 못 찾은 채로 남는다 — 남의 이미지를 자기 결과라고 우기지 않는다.
    try testing.expect(!out.items[0].result.found);
}

test "접기: id 가 다르면 남의 이미지로 접히지 않는다 (§2.2.1 적대적)" {
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01AB","name":"Read","input":{"file_path":"/tmp/a.png"}}]}}
        \\{"parentUuid":"p","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_ZZZZ","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"AAAABBBB","media_type":"image/png"}}]}]}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(no_fold, out.items[1].fold_owner); // 주인을 못 찾았으면 제 줄로 선다
    try testing.expect(!out.items[0].result.found);
}

test "활동 결말: Codex 결과가 몇 줄 뒤여도 붙는다 — 사이에 reasoning 이 낀다 (AV2)" {
    // 실측 거리: Claude 중앙 1 · Codex 중앙 3 · 최대 48. **줄 창을 고정하지 않는다**는 계약이 이것이다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_A1","type":"custom_tool_call","name":"exec","input":"ls -la"}}
        \\{"payload":{"type":"reasoning","summary":[]}}
        \\{"payload":{"type":"reasoning","summary":[]}}
        \\{"payload":{"type":"reasoning","summary":[]}}
        \\{"payload":{"call_id":"call_A1","type":"custom_tool_call_output","output":"exit=1\nboom"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].result.found);
    try testing.expectEqual(@as(u32, 2), out.items[0].result.lines);
    // 첫 줄이 도구가 쓴 상태 줄이고 코드가 0 이 아니다.
    try testing.expect(out.items[0].result.failed);
}

test "활동 결말: 끝나지 않은 호출은 요약이 없다 — 0 줄이라고 적지 않는다 (AV2)" {
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_ZZ","type":"custom_tool_call","name":"exec","input":"sleep 999"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(!out.items[0].result.found);
    try testing.expectEqual(@as(u32, 0), out.items[0].result.lines);
}

test "활동 결말: id 가 다르면 남의 결과를 안 집는다 (AV2)" {
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_X","type":"custom_tool_call","name":"exec","input":"first"}}
        \\{"payload":{"call_id":"call_Y","type":"custom_tool_call","name":"exec","input":"second"}}
        \\{"payload":{"call_id":"call_Y","type":"custom_tool_call_output","output":"only mine"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    // 앞의 호출은 **결과가 없다**. 뒤의 것에만 붙는다.
    try testing.expect(!out.items[0].result.found);
    try testing.expect(out.items[1].result.found);
    try testing.expectEqual(@as(u32, 1), out.items[1].result.lines);
}

test "활동 결말: `\\n` 은 개행이 아니다 — 실측 24% 오차의 회귀 가드 (AV2)" {
    // 실측(2026-09-07): Codex 결과의 **24.0%** 가 이스케이프된 백슬래시였다. 그냥 세면 3 줄짜리가
    // 12 줄이 된다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_E","type":"custom_tool_call","name":"exec","input":"grep"}}
        \\{"payload":{"call_id":"call_E","type":"custom_tool_call_output","output":"printf 'a\\nb'"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].result.found);
    try testing.expectEqual(@as(u32, 1), out.items[0].result.lines);
}

test "활동 결말: Codex 배열 출력도 원소를 전부 센다 (AV2)" {
    // 실측: 출력 184,202 건 중 **135,085 건이 배열**이고 원소는 평균 2.09 개다. 첫 원소만 세면 조용히 모자란다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_L","type":"function_call","name":"shell","arguments":"ls"}}
        \\{"payload":{"call_id":"call_L","type":"function_call_output","output":[{"type":"output_text","text":"a\nb"},{"type":"output_text","text":"c\nd"}]}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].result.found);
    try testing.expectEqual(@as(u32, 3), out.items[0].result.lines);
}

test "활동 결말: compacted 안의 결과는 안 붙는다 — 지나간 호출에 남의 결말이 붙지 않게 (AV2)" {
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_C","type":"custom_tool_call","name":"exec","input":"ls"}}
        \\{"payload":{"type":"compacted","message":"{\"call_id\":\"call_C\",\"type\":\"custom_tool_call_output\",\"output\":\"old\"}"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(!out.items[0].result.found);
}

test "활동 결말: 출력 레코드 자신은 호출로 안 세어진다 (AV2)" {
    // `"custom_tool_call"` 마커가 `"custom_tool_call_output"` 에 걸리면 결과 줄마다 유령 호출이 선다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_O","type":"custom_tool_call_output","output":"orphan"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "활동 결말: 줄 수를 모르면 「0 줄」이라고 적지 않는다 (AV2 · §2.2.1 이 갱신)" {
    // 적대적 검증 1 회차가 세운 판정자다. 본문을 못 읽었는데 `found=true, lines=0` 이면 화면이
    // **「0줄」이라고 거짓말**한다. 실측: 247 MB Claude 세션에서 그런 결과가 380 건(3.9%)이고,
    // 전부 본문이 **이미지·참조 블록**이라 줄 수가 애초에 없는 것들이다.
    //
    // ⚠️ **그중 이미지 쪽은 §2.2.1 이 답을 바꿨다.** 그때는 「모른다(`found=false`)」로 두는 것이
    // 유일한 정직한 답이었는데, 지금은 **「이미지」라고 말할 수 있다** — 그러면 접기도 서고 요약도
    // 거짓이 아니다. 이 판정자가 지키던 성질(「0 줄」이라고 적지 않는다)은 그대로 지킨다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_09IM","name":"Read","input":{"file_path":"/tmp/a.png"}}]}}
        \\{"type":"user","message":{"content":[{"tool_use_id":"toolu_09IM","type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJD"}}]}]}}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_09RF","name":"Read","input":{"file_path":"/tmp/b.txt"}}]}}
        \\{"type":"user","message":{"content":[{"tool_use_id":"toolu_09RF","type":"tool_result","content":[{"type":"tool_use_ref","ref":"x"}]}]}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);

    var image_call: ?Hit = null;
    var ref_call: ?Hit = null;
    for (out.items) |h| {
        if (h.kind.isImage()) continue;
        if (h.result.image) image_call = h else ref_call = h;
    }

    // ── ① **이미지 결과는 이제 말할 수 있다** — 줄 수가 아니라 종류로.
    try testing.expect(image_call != null);
    try testing.expect(image_call.?.result.found);
    try testing.expectEqual(@as(u32, 0), image_call.?.result.lines);
    // 화면이 「0줄」이라고 적지 않는 근거가 이 값이다(`formatResultSummary` 가 이것으로 갈린다).
    try testing.expect(image_call.?.result.image);

    // ── ② **이미지도 아니고 본문도 못 읽으면 여전히 「모른다」다.** 참조 블록이 그 경우다 —
    //    여기서 `found` 가 서면 화면이 「0줄」이라고 거짓말한다(이 판정자의 원래 물음).
    try testing.expect(ref_call != null);
    try testing.expect(!ref_call.?.result.found);
}

test "활동 결말: 빈 결과는 «0 줄» 이라는 사실이다 (AV2)" {
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_EMPTY","type":"custom_tool_call","name":"exec","input":"true"}}
        \\{"payload":{"call_id":"call_EMPTY","type":"custom_tool_call_output","output":""}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    // 찾았고(=결과가 왔고), 줄 수는 0 이다. 위 판정자의 「못 찾았다」와 **다른 사실**이다.
    try testing.expect(out.items[0].result.found);
    try testing.expectEqual(@as(u32, 0), out.items[0].result.lines);
}

test "활동 결말: 기다림은 개수로 유계다 — 너무 멀면 안 붙는다 (AV2)" {
    // `max_pending_calls` 는 **줄 창이 아니라 개수 창**이다(계약 §3.2). 그 사이를 실제로 넘겨 본다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    try doc.appendSlice(allocator,
        \\{"payload":{"call_id":"call_FIRST","type":"custom_tool_call","name":"exec","input":"first"}}
    );
    try doc.append(allocator, '\n');
    var i: usize = 0;
    while (i < max_pending_calls) : (i += 1) {
        try doc.print(
            allocator,
            "{{\"payload\":{{\"call_id\":\"call_f{d}\",\"type\":\"custom_tool_call\",\"name\":\"exec\",\"input\":\"x\"}}}}\n",
            .{i},
        );
    }
    try doc.appendSlice(allocator,
        \\{"payload":{"call_id":"call_FIRST","type":"custom_tool_call_output","output":"too late"}}
    );
    try doc.append(allocator, '\n');
    try scanDocForTest(allocator, doc.items, &out);
    try testing.expectEqual(max_pending_calls + 1, out.items.len);
    // 첫 호출은 링에서 밀려났다 — 결말이 안 붙는다(틀린 결말이 붙는 것보다 낫다).
    try testing.expect(!out.items[0].result.found);
    // 그리고 **아무 데도 잘못 붙지 않았다**.
    for (out.items) |h| try testing.expect(!h.result.found);
}

test "활동 결말: 같은 id 의 두 번째 결과가 앞의 결말을 덮지 않는다 (AV2)" {
    // 적대적 검증 4 회차 — 뮤테이션(쓴 자리를 안 죽인다)이 **살아남아** 이 판정자가 생겼다.
    // 죽이는 것은 표시만의 문제가 아니다: 살아 있는 기다림 수(`pending_live`)가 같은 자리에서 두 번
    // 줄어 **0 아래로 내려간다**(usize 라 즉사한다).
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    // ⚠️ **다른 호출 하나를 살려 둔다.** 안 그러면 살아 있는 기다림이 0 이 되어 짧은 회로가 먼저
    // 막아 버리고, 그러면 이 판정자가 「쓴 자리를 죽이는가」를 못 잰다(4 회차에서 실제로 그랬다).
    const doc =
        \\{"payload":{"call_id":"call_DUP","type":"custom_tool_call","name":"exec","input":"ls"}}
        \\{"payload":{"call_id":"call_OTHER","type":"custom_tool_call","name":"exec","input":"sleep"}}
        \\{"payload":{"call_id":"call_DUP","type":"custom_tool_call_output","output":"a\nb\nc"}}
        \\{"payload":{"call_id":"call_DUP","type":"custom_tool_call_output","output":"x\ny\nz\nw\nv\nu\nt\ns\nr\nq"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(out.items[0].result.found);
    // **첫 결과가 이긴다** — 계약 §3.2 의 「id 가 맞는 **첫** 결과 레코드를 집는다」가 그 규칙이다.
    try testing.expectEqual(@as(u32, 3), out.items[0].result.lines);
}

// ── AV2b 판정자 — 시각의 자리는 provider 마다 반대다 ─────────────────────────────────────────

/// 그 `Hit` 이 가리키는 시각 값(줄 안에서). 자리 판정만 보는 판정자용.
fn timeValueForTest(line: []const u8, hit: Hit) []const u8 {
    if (hit.time_rel == 0) return "";
    const from = hit.time_rel + timestamp_key.len;
    if (from >= line.len) return "";
    const end = std.mem.indexOfScalarPos(u8, line, from, '"') orelse return "";
    return line[from..end];
}

test "활동 시각: Claude 는 마커 **뒤**, Codex 는 줄 **머리** — 반대편을 보면 못 찾는다 (AV2b)" {
    // AV1-b 가 시각을 미룬 이유가 이 비대칭이다(실측 2026-09-07): Claude 는 100% 가 마커 뒤이고
    // 중앙 1,454 · 최대 38,753, Codex 는 100% 가 자리 **1** 이다. 이미지 경로(payload 앞뒤 창)를
    // 그대로 쓰면 한쪽은 못 보고, 잘못하면 남의 시각을 집는다.
    const allocator = testing.allocator;
    {
        var out: std.ArrayList(Hit) = .empty;
        defer out.deinit(allocator);
        const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\"," ++
            "\"id\":\"toolu_01\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\",\"description\":\"목록\"}}]}," ++
            "\"timestamp\":\"2026-09-07T01:13:13.040Z\"}";
        try scanLine(allocator, line, 0, &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqualStrings("2026-09-07T01:13:13.040Z", timeValueForTest(line, out.items[0]));
    }
    {
        var out: std.ArrayList(Hit) = .empty;
        defer out.deinit(allocator);
        const line = "{\"timestamp\":\"2026-09-04T12:42:04.137Z\",\"payload\":{\"call_id\":\"call_A\"," ++
            "\"type\":\"custom_tool_call\",\"name\":\"exec\",\"input\":\"ls -la\"}}";
        try scanLine(allocator, line, 0, &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqualStrings("2026-09-04T12:42:04.137Z", timeValueForTest(line, out.items[0]));
    }
}

test "활동 시각: Claude 는 마커 앞의 시각을 안 집는다 — 남의 시각을 붙이지 않는다 (AV2b)" {
    // 줄 머리에 다른 시각이 있고 레코드의 진짜 시각이 뒤에 있을 때, **뒤엣것**이 이 호출의 것이다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const line = "{\"timestamp\":\"1999-01-01T00:00:00.000Z\",\"message\":{\"content\":[{\"type\":\"tool_use\"," ++
        "\"id\":\"toolu_02\",\"name\":\"Read\",\"input\":{\"file_path\":\"/tmp/a.txt\"}}]}," ++
        "\"timestamp\":\"2026-09-07T02:00:00.000Z\"}";
    try scanLine(allocator, line, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("2026-09-07T02:00:00.000Z", timeValueForTest(line, out.items[0]));
}

test "활동 시각: 없으면 0 이다 — 지어내지 않는다 (AV2b)" {
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const line = "{\"payload\":{\"call_id\":\"call_B\",\"type\":\"custom_tool_call\",\"name\":\"exec\",\"input\":\"ls\"}}";
    try scanLine(allocator, line, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 0), out.items[0].time_rel);
}

test "활동 결말: 본문의 자리를 든다 — 펼침이 그 바이트를 다시 읽는다 (AV3)" {
    // 계약 §2.4: 「자리(offset)만 들고 있다가 펼칠 때 그 구간만 읽는다」. 바이트를 담으면 세션당
    // 12,200 개 × 최대 2.8 MB 다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_OFF","type":"custom_tool_call","name":"exec","input":"ls"}}
        \\{"payload":{"call_id":"call_OFF","type":"custom_tool_call_output","output":"first\nsecond"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const r = out.items[0].result;
    try testing.expect(r.found);
    // 그 자리에서 시작하는 바이트가 **본문의 첫 글자**여야 한다(파일 절대 오프셋이다).
    try testing.expect(r.body.offset > 0);
    try testing.expectEqualStrings("first", doc[r.body.offset..][0..5]);
}

test "Codex 활동: JS 껍데기를 벗겨 안쪽 도구와 명령을 든다 (2026-07 형식)" {
    // **실측이 이 규칙을 요구했다**(2026-09-10, 이 맥의 Codex 세션 229,634 호출): `exec` 가 셸이
    // 아니라 **JavaScript** 를 받게 되면서(2026-07 부터 · 2026-09 는 93.7%), 화면의 이름 칸은
    // **74.4% 가 `exec` 하나**가 되고 대상 칸은 줄마다 `const r = await tools.exec_command({"cmd":"`
    // 로 시작했다 — 「무엇을 돌렸나」를 훑는 화면인데 두 칸이 정보 0 이었다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_A","type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"rg -n foo src/\",\"workdir\":\"/tmp\"});\ntext(r);\n"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const h = out.items[0];
    // 이름은 **안쪽** 것이다 — 바깥 `exec` 는 껍데기다.
    try testing.expectEqualStrings("exec_command", doc[h.name_rel .. h.name_rel + h.name_len]);
    // 대상은 인자의 **첫 문자열 값**. 파일 바이트라 이스케이프는 그대로다(푸는 것은 라벨 층의 일).
    try testing.expectEqualStrings("rg -n foo src/", doc[h.data_offset .. h.data_offset + h.data_len]);
}

test "Codex 활동: 실제 모양 — 맨몸 키 · 홑따옴표 · 두 겹 이스케이프 (2026-09 실측)" {
    // **실측 그대로의 바이트다.** 키가 `\"cmd\"` 가 아니라 **맨몸 `cmd:`** 인 것이 62.6% 이고,
    // 값 안에는 홑따옴표(`<<'JS'`)와 **두 겹 이스케이프**(`\\n`)가 섞인다. 합성 픽스처만 보면
    // 이 셋을 다 놓친다 — 실제 화면이 안 벗겨지는 것을 보고서야 드러났다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call_R","name":"exec","input":"text(await tools.exec_command({cmd:\"node --input-type=module <<'JS'\\nimport assert from 'node:assert/strict';\\nJS\",max_output_tokens:16000}));\n"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const h = out.items[0];
    try testing.expectEqualStrings("exec_command", doc[h.name_rel .. h.name_rel + h.name_len]);
    const target = doc[h.data_offset .. h.data_offset + h.data_len];
    try testing.expect(std.mem.startsWith(u8, target, "node --input-type=module"));
    // 껍데기(`text(await tools.`)가 남아 있으면 안 벗겨진 것이다.
    try testing.expect(std.mem.indexOf(u8, target, "tools.") == null);
}

test "Codex 활동: 실제 rollout 줄 그대로 (2026-09-05 · 경로만 가림)" {
    // **의역하지 않는다.** 합성 픽스처는 통과하는데 실제 화면이 안 벗겨졌다 — 그 차이를 잡으려면
    // 파일에서 그대로 떠 온 바이트여야 한다(개인 경로만 `/Users/me` 로 가렸다, 계약 §5).
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"timestamp":"2026-09-05T09:39:56.951Z","ordinal":30,"type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_01e0015f0a49ad0f016a9be36aeffc87d0b40836b75d2a9258","status":"completed","call_id":"call_ihhiu7Ta2gwS1LTyLB23Glkl","name":"exec","input":"text(await tools.exec_command({cmd:\"rg -n 'hwpjs' /Users/me/.codex/memories/MEMORY.md; git status --short; rg --files js src/wasm tests/cfb; pwd\",\"max_output_tokens\":4000}));\n","internal_chat_message_metadata_passthrough":{"turn_id":"01a070f0-3dd7-73d1-809b-f525ea72fe27","create_time":1788601190.770177}}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const h = out.items[0];
    try testing.expectEqualStrings("exec_command", doc[h.name_rel .. h.name_rel + h.name_len]);
    const target = doc[h.data_offset .. h.data_offset + h.data_len];
    try testing.expect(std.mem.indexOf(u8, target, "tools.") == null);
}

test "Codex 활동: 값 안에 홑따옴표와 두 겹 이스케이프가 섞인 실제 줄 (2026-09-05)" {
    // **화면에서 이 줄만 안 벗겨졌다.** 다른 줄들은 벗겨지는데 `node --input-type=module <<'JS'`
    // 만 껍데기가 남았다 — 값 안의 **홑따옴표**와 **두 겹 이스케이프**(`\\n`)가 원인 후보다.
    // 실제 바이트로 재야 그 차이가 잡힌다(경로만 `/Users/me` 로 가렸다).
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"timestamp":"2026-09-05T09:50:40.477Z","ordinal":149,"type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_01e0015f0a49ad0f016a9be5db459c87d08bbd7dc33107372a","status":"completed","call_id":"call_00rJkvNIE09dCxmIMHxfubxo","name":"exec","input":"text(await tools.exec_command({cmd:\"node --input-type=module <<'JS'\\nimport assert from 'node:assert/strict';\\nimport {readFileSync} from 'node:fs';\\nimport {runInNewContext} from 'node:vm';\\nimport {createCfbReader} from './js/cfb.mjs';\\nimport {v4File} from './tests/cfb/contract-fixtures.mjs';\\nconst api=await createCfbReader(readFileSync('/tmp/hwpjs-boundary-rereview.rfLfUp/out/bin/hwpjs.wasm'));\\nlet searches=0, rejected=0, accepted=0;\\nconst fixture=v4File();fixture[12288]=173;\\nconst padded=new Uint8Array(fixture.length+31);padded.set(fixture,17);\\nconst foreign=runInNewContext('const a=new Uint8Array(bytes.length+31);a.set(bytes,17);a.subarray(17,17+bytes.length)',{bytes:Array.from(fixture)});\\nconst shared=new Uint8Array(new SharedArrayBuffer(fixture.length));shared.set(fixture);\\nfor(const input of [fixture,Array.from(fixture),Uint8Array.from(fixture).buffer,padded.subarray(17,17+fixture.length),foreign,shared]){const d=api.parse(input,{raw:true});assert.equal(d.FileIndex[1].content[0],173);assert.deepEqual(d.raw.header,Uint8Array.from(fixture.subarray(0,4096)));accepted++;}\\nconst saved=api.parse(fixture);const detached=Uint8Array.from(fixture).buffer;structuredClone(detached,{transfer:[detached]});\\nfor(const input of [null,undefined,{},new DataView(fixture.buffer),Uint16Array.from(fixture),new Uint8ClampedArray(fixture),[1,,3],detached,{[Symbol.toStringTag]:'ArrayBuffer',byteLength:fixture.length}]){assert.throws(()=>api.parse(input));assert.equal(api.find(saved,'\\\\ufffd'),saved.FileIndex[1]);rejected++;}\\nfor(const name of ['\\\\ufeffX','X\\\\ufeff','\\\\ufeff\\\\ufeff','\\\\ufffd','😀','한글','Straße','Σςσ','\\\\u0001Data','e\\\\u0301']){\\n const b=v4File();b.fill(0,8320,8384);const encoded=Buffer.from(name+'\\\\0','utf16le');encoded.copy(b,8320);b.writeUInt16LE(encoded.length,8384);\\n const d=api.parse(b);assert.equal(d.FileIndex[1].name,name);\\n for(let phase=0;phase<4;phase++){\\n  if(phase===1) api.parse(fixture);\\n  if(phase===2) assert.throws(()=>api.parse(new Uint8Array(0)));\\n  if(phase===3) api.close();\\n  for(const query of [name,'/'+name]){assert.equal(api.find(d,query),d.FileIndex[1],JSON.stringify({name,query,phase}));searches++;}\\n }\\n}\\napi.close();api.close();\\nconsole.log(JSON.stringify({acceptedByteVariants:accepted,rejectedInputsAndRetainedState:rejected,unicodeLifecycleSearches:searches,passed:true}));\\nJS\\n git status --short\",\"yield_time_ms\":1000,\"max_output_tokens\":1700}));\n","internal_chat_message_metadata_passthrough":{"turn_id":"01a070f8-91fa-7e12-9458-f6c6d5ea4f19","create_time":1788601809.083574}}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const h = out.items[0];
    try testing.expectEqualStrings("exec_command", doc[h.name_rel .. h.name_rel + h.name_len]);
    const target = doc[h.data_offset .. h.data_offset + h.data_len];
    try testing.expect(std.mem.startsWith(u8, target, "node --input-type=module"));
}

test "Codex 활동: 명령 안의 따옴표에서 잘리지 않는다 — 이스케이프가 두 겹이다 (적대적 3회차)" {
    // 🔥 **실측 1,625 건(활동 줄의 10.2%)이 여기서 잘렸다.** JS 문자열의 따옴표는 파일에 `\"` 로
    // 적히고, **그 안에서 다시 이스케이프된** 따옴표는 `\\\"` 로 적힌다(백슬래시가 JSON 한 겹 ·
    // JS 한 겹). JS 층을 안 보면 그 `\"` 를 **값의 끝**으로 읽어 `rg -n \\` 만 남는다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_X","type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({cmd:\"rg -n \\\"needle\\\" src\"});"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const h = out.items[0];
    try testing.expectEqualStrings("exec_command", doc[h.name_rel .. h.name_rel + h.name_len]);
    // 따옴표를 지나 **명령 끝까지** 온다.
    try testing.expectEqualStrings(
        \\rg -n \\\"needle\\\" src
    , doc[@intCast(h.data_offset)..][0..h.data_len]);
}

test "Codex 활동: 감싼 글자가 또 이스케이프면 그것까지 지난다 (적대적 3회차 · 실측 22 건)" {
    // JS 소스의 `\\\\` 바로 뒤에 `\\"` 가 오는 자리다. 백슬래시 하나만 지나고 멈추면 그 다음
    // `\\"` 를 **값의 끝**으로 읽는다 — 실측 300 MB 에서 22 건이 그 자리에서 잘렸다(가장 긴 것은
    // 203 B 가 142 B 로).
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_Y","type":"custom_tool_call","name":"exec","input":"await tools.exec_command({cmd:\"a\\\\\\\"b\"});"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const h = out.items[0];
    try testing.expectEqualStrings(
        \\a\\\\\\\"b
    , doc[@intCast(h.data_offset)..][0..h.data_len]);
}

test "Codex 활동: 한 줄의 일감은 후보 수로 못 박힌다 (적대적 2회차 · 성능)" {
    // 🔥 **이것이 없으면 한 줄이 O(후보 × 창) 이다.** 후보마다 `firstArgString` 이 4 KiB 창 끝까지
    // 갈 수 있으므로, 창을 `tools.a(` 로 꽉 채우면 후보가 510 개 나오고 한 줄에 2 MB 를 훑는다.
    // 실측(2026-09-10 · ReleaseFast): 그런 줄로만 채운 65 MB 문서가 **483 → 9 MB/s (53배)** 로
    // 무너졌다. 못 둘을 박았다 — ① 창을 다 쓴 후보를 만나면 멈춘다(뒤 후보는 같은 바이트의
    // 뒷부분만 본다), ② 그래도 `max_inner_calls` 로 개수를 자른다. 고친 뒤 **354 MB/s**.
    //
    // 시계로 재지 않는 이유: 느린 CI 에서 간헐 실패가 된다. **일감의 상한**인 후보 수를 직접 본다.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(testing.allocator);
    try line.appendSlice(testing.allocator, "{\\\"cmd\\\":\\\"ls\\\"};");
    var k: usize = 0;
    while (k < 510) : (k += 1) try line.appendSlice(testing.allocator, "tools.a(");

    var examined: usize = 0;
    const call = pickCodexInnerCallCounting(line.items, 0, @min(line.items.len, max_inner_scan_bytes), &examined);
    // 값이 하나도 없으므로 첫 후보가 창을 다 쓰고, 거기서 멈춘다.
    try testing.expectEqual(@as(usize, 1), examined);
    try testing.expect(call != null);
    try testing.expectEqualStrings("a", line.items[call.?.name.start .. call.?.name.start + call.?.name.len]);
    try testing.expect(call.?.target == null);
}

test "Codex 활동: 구조상 일찍 되돌아오는 후보도 개수로 잘린다 (적대적 2회차 · 상한)" {
    // 앞 판정자의 멈춤은 **창을 다 쓴** 후보만 잡는다. 축약 프로퍼티처럼 **구조를 보고 일찍**
    // 되돌아오는 후보는 그 멈춤에 안 걸리므로, 그런 후보만 늘어놓으면 다시 후보 수만큼 돈다.
    // `max_inner_calls` 가 두 번째 못이다.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(testing.allocator);
    var k: usize = 0;
    while (k < 510) : (k += 1) try line.appendSlice(testing.allocator, "tools.a({x,y});");

    var examined: usize = 0;
    _ = pickCodexInnerCallCounting(line.items, 0, @min(line.items.len, max_inner_scan_bytes), &examined);
    try testing.expectEqual(max_inner_calls, examined);
}

test "Codex 활동: 값이 뒤에 있으면 창을 다 써도 찾아낸다 (적대적 2회차 · 손실 없음)" {
    // 멈춤이 **일찍 포기하는 것**이 되면 안 된다. 안 닫히는 호출이 잔뜩 앞서도, 그 첫 후보의 훑기가
    // 뒤의 값을 그대로 지나가며 집는다 — 그래서 후보 하나로 끝난다(빠르면서 손실이 없다).
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(testing.allocator);
    var k: usize = 0;
    while (k < 200) : (k += 1) try line.appendSlice(testing.allocator, "tools.a(");
    try line.appendSlice(testing.allocator, "tools.exec_command({\\\"cmd\\\":\\\"rg -n needle\\\"})");

    var examined: usize = 0;
    const call = pickCodexInnerCallCounting(line.items, 0, line.items.len, &examined);
    try testing.expectEqual(@as(usize, 1), examined);
    try testing.expect(call != null);
    const t = call.?.target.?;
    try testing.expectEqualStrings("rg -n needle", line.items[t.start .. t.start + t.len]);
}

test "Codex 활동: 갈래도 **안쪽 이름**이 정한다 — 표가 그 어휘를 안다" {
    // 🔥 **표를 먼저 넓히지 않고 이 줄만 바꾸면 「명령」이 무너진다.** 앞선 슬라이스가 실측으로
    // 확인했다 — `fromToolName` 이 `exec_command`·`write_stdin` 을 모르던 때 갈래를 안쪽 이름으로
    // 옮기자 **실행이 171,379 → 106** 으로 떨어지고 74.6% 가 「그 밖」으로 갔다.
    //
    // 지금은 표가 그 어휘를 안다. 그래서 안쪽 이름이 갈래를 정해도 이 호출은 「명령」에 남는다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_X","type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"ls\"});\n"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const h = out.items[0];
    // 화면에 적을 이름은 **안쪽** 것이다.
    try testing.expectEqualStrings("exec_command", doc[h.name_rel .. h.name_rel + h.name_len]);
    // 갈래도 그 이름이 정한다 — 「명령」 필터가 이 줄을 계속 담아야 한다.
    try testing.expectEqual(Activity.exec, h.activity);
}

test "Codex 활동: 돌고 있는 셸에 보내는 입력도 「명령」이다 — `write_stdin`" {
    // 실측 **82,027 건**으로 `exec_command` 다음이다. 이름은 「표준입력에 쓴다」지만 사용자가 묻는
    // 것은 「무엇을 돌렸나」이고, 돌고 있는 셸에 친 글자는 그 답의 일부다 — 같은 칸에 든다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_W","type":"custom_tool_call","name":"exec","input":"await tools.write_stdin({session_id:1,chars:\\"y\\\\n\\"});"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const h = out.items[0];
    try testing.expectEqualStrings("write_stdin", doc[h.name_rel .. h.name_rel + h.name_len]);
    try testing.expectEqual(Activity.exec, h.activity);
}

test "Codex 활동: 파일을 고치는 일은 「명령」이 아니다 — `apply_patch` 는 그 밖이다" {
    // 🔥 **실측 24,558 건이 「명령」에 잘못 들어앉아 있었다.** 바깥 이름이 언제나 `exec` 라서다.
    // 파일을 고치는 일은 Claude 의 `Edit`·`Write` 와 같은 칸이어야 한다 — 그래야 두 provider 가
    // 같은 물음에 같은 답을 준다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_P","type":"custom_tool_call","name":"exec","input":"await tools.apply_patch({input:\\"*** Begin Patch\\"});"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(Activity.other, out.items[0].activity);
}

test "Codex 활동: 그림을 여는 일은 「읽기」다 — 껍데기가 가리고 있었다" {
    // 계약 §2.1 표가 「읽기 … Codex `view_image`」라고 적는데도 실측 226 건이 **실행으로** 갔다.
    // 바깥 이름이 `exec` 였기 때문이다 — 문서가 코드보다 많이 약속하던 자리다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_V","type":"custom_tool_call","name":"exec","input":"await tools.view_image({path:\\"/tmp/shot.png\\"});"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(Activity.read, out.items[0].activity);
}

test "Codex 활동: 모르는 안쪽 이름은 **바깥으로 안 돌아간다**" {
    // 바깥은 언제나 `exec` 이므로 돌아가면 **모르는 도구가 전부 「명령」**이 된다. 껍데기를 벗긴
    // 이상 안쪽 이름이 그 호출의 진짜 이름이고, 모르면 `other` 가 정확한 답이다(§2.3).
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_M","type":"custom_tool_call","name":"exec","input":"await tools.mcp__codex_apps__github_get_pr_info({url:\\"https://x/pull/1\\"});"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(Activity.other, out.items[0].activity);
}

test "Codex 활동: 옛 형식은 **바깥 이름**이 같은 어휘다 — 표 하나로 둘 다 든다" {
    // ⚠️ **어휘가 두 벌이 아니라 자리가 두 벌이다.** 같은 `exec_command` 가 세션에 따라 껍데기
    // 안쪽으로 오기도 하고(197,921 건) 바깥 이름으로 곧장 오기도 한다(실측 117,413 건 중 41,509).
    // 표가 이름 하나만 알면 둘 다 제자리에 든다 — 그 전에는 이 41,509 건이 「그 밖」에 갇혀 있었다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_O","type":"custom_tool_call","name":"exec_command","input":"{\\"cmd\\":\\"ls -al\\"}"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(Activity.exec, out.items[0].activity);
}

test "Codex 활동: 껍데기를 못 벗기면 옛 동작 그대로다 (폴백)" {
    // **형식이 두 달 만에 뒤집혔다** — 2026-06 까지 `tools.X(` 는 0% 였고 그때 세션(실측 35,126 건)이
    // 지금도 남아 있다. 규칙은 **언제나 물러날 자리**를 가져야 한다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_B","type":"custom_tool_call","name":"exec","input":"ls -la"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const h = out.items[0];
    try testing.expectEqualStrings("exec", doc[h.name_rel .. h.name_rel + h.name_len]);
    try testing.expectEqualStrings("ls -la", doc[h.data_offset .. h.data_offset + h.data_len]);
}

test "Codex 활동: 인자 범위를 벗어나 남의 값을 집지 않는다 (적대적)" {
    // 두 결함이 같은 뿌리였다 — **인자 범위를 안 지키면** ⑴ `tools.get_goal({})` 처럼 인자가 빈
    // 호출이 **뒤에 이어지는 다른 호출**의 값을 집고, ⑵ `{cmd, workdir:"…"}` 처럼 첫 키가
    // **축약 프로퍼티**면 그 다음 키를 집어 줄마다 같은 디렉터리가 떴다(실측 338 건).
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);

    // ⑴ 빈 인자 — 뒤의 `exec_command` 값을 집으면 안 된다. 이름은 안쪽 것을 쓰되 대상은 폴백이다.
    const doc_empty =
        \\{"payload":{"call_id":"call_C","type":"custom_tool_call","name":"exec","input":"const g = await tools.get_goal({});\nconst r = await tools.exec_command({\"cmd\":\"echo hi\"});\n"}}
        \\
    ;
    try scanDocForTest(allocator, doc_empty, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    // **이름과 대상이 같은 호출에서** 나와야 한다. 첫 호출(`get_goal`)은 인자가 비었으므로 그 이름에
    // 뒤 호출의 값을 붙이면 둘이 다른 일을 가리킨다 — **대상까지 있는 첫 호출**을 고른다.
    try testing.expectEqualStrings("exec_command", doc_empty[out.items[0].name_rel..][0.."exec_command".len]);
    try testing.expectEqualStrings("echo hi", doc_empty[out.items[0].data_offset..][0.."echo hi".len]);

    // ⑵ 축약 프로퍼티 — `workdir` 을 집으면 안 된다.
    out.clearRetainingCapacity();
    const doc_short =
        \\{"payload":{"call_id":"call_D","type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({cmd, workdir:\"/Users/me/repo\"});\n"}}
        \\
    ;
    try scanDocForTest(allocator, doc_short, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("exec_command", doc_short[out.items[0].name_rel..][0.."exec_command".len]);
    // 대상은 **폴백**(입력 전체)이어야 한다 — `workdir` 을 집으면 줄마다 같은 디렉터리가 뜬다.
    const t2 = doc_short[out.items[0].data_offset..][0..out.items[0].data_len];
    try testing.expect(std.mem.startsWith(u8, t2, "const r = await"));
}

test "Codex 활동: 빈 문자열도 값이다 — 건너뛰지 않는다 (적대적)" {
    // 「빈 값은 건너뛴다」를 넣으려다 실측이 기각했다: 일치율이 **99.99% → 63.5%** 로 떨어진다.
    // `write_stdin` 의 `chars` 는 **정말 빈 값일 때가 많다**(Enter 만 보내는 것이다).
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_E","type":"custom_tool_call","name":"exec","input":"const r = await tools.write_stdin({\"session_id\":14298,\"chars\":\"\",\"yield_time_ms\":1000});\n"}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const h = out.items[0];
    // 이름은 안쪽 것으로 나아진다.
    try testing.expectEqualStrings("write_stdin", doc[h.name_rel .. h.name_rel + h.name_len]);
    // ⚠️ **대상은 폴백이다.** `chars` 가 빈 값이라 그대로 쓰면 `appendActivity` 가 이 줄을 통째로
    // 버린다(실측 55,416 건이 사라진다) — 껍데기라도 보이는 편이 낫다. 줄이 **살아 있는 것**이
    // 이 판정자가 지키는 것이다.
    try testing.expect(h.data_len > 0);
    try testing.expect(std.mem.indexOf(u8, doc[h.data_offset .. h.data_offset + h.data_len], "write_stdin") != null);
}

test "활동 결말: Codex 결과가 배열이면 자리는 여는 [ 다음이고 그 사실을 든다 (적대적 2회차)" {
    // **가운데 층이 비어 있었다.** 순수 모듈이 「배열을 어떻게 푸나」를 재고 제품 판정자가
    // end-to-end 를 재는데, **스캐너가 어디를 가리키나**는 그 층에서 아무도 안 쟀다 — 위의
    // 「Codex 본문 자리는 값의 첫 바이트다」가 **문자열 케이스만** 본다.
    //
    // 이 자리의 뜻은 이 슬라이스에서 **바뀌었다**(첫 원소의 값 → 여는 `[` 다음). 뜻이 바뀐 필드는
    // 그 층에서 못박아야 다음 사람이 옛 뜻으로 되돌리지 못한다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"payload":{"call_id":"call_ARR","type":"custom_tool_call","name":"exec","input":"ls"}}
        \\{"payload":{"call_id":"call_ARR","type":"custom_tool_call_output","output":[{"type":"input_text","text":"head\n"},{"type":"input_text","text":"body"}]}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const r = out.items[0].result;
    try testing.expect(r.found);
    // **사실을 값으로 든다** — 소비자가 바이트를 보고 짐작하면 규칙이 두 벌이 된다.
    try testing.expect(r.body.is_array);
    // 자리는 여는 `[` **다음** = 첫 원소의 `{` 다. 여기서 시작해야 소비자가 원소를 걸어갈 수 있다.
    try testing.expectEqualStrings("{\"type\"", doc[r.body.offset..][0..7]);

    // 문자열 결과는 **여전히 값의 첫 바이트**이고 배열이 아니라고 말한다(둘이 갈려 있어야 한다).
    out.clearRetainingCapacity();
    const doc_str =
        \\{"payload":{"call_id":"call_STR","type":"custom_tool_call","name":"exec","input":"ls"}}
        \\{"payload":{"call_id":"call_STR","type":"custom_tool_call_output","output":"plain"}}
        \\
    ;
    try scanDocForTest(allocator, doc_str, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const rs = out.items[0].result;
    try testing.expect(!rs.body.is_array);
    try testing.expectEqualStrings("plain", doc_str[rs.body.offset..][0..5]);
}

test "활동 결말: Claude 본문 자리도 값의 첫 바이트다 (AV3)" {
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const doc =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_0F","name":"Bash","input":{"command":"ls","description":"목록"}}]}}
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_0F","content":"alpha\nbeta"}]}}
        \\
    ;
    try scanDocForTest(allocator, doc, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const r = out.items[0].result;
    try testing.expect(r.found);
    try testing.expectEqualStrings("alpha", doc[r.body.offset..][0..5]);
}

test "펼침 대상: 라벨은 요약이어도 펼침은 **명령**을 가리킨다 (AV3 적대적)" {
    // 계약 §2.2 ⚠️ 가 명시적으로 갚기로 한 대가다 — 「`description` 은 명령과 어긋날 수 있다, **그래서
    // 펼치면 언제나 명령 전문이 먼저 나온다**」. 라벨 대상을 그대로 읽으면 같은 요약을 두 번 보여 주고
    // 명령은 영영 안 보인다(실측: Claude Bash 의 68.8% 가 `description` 을 든다).
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_C1\"," ++
        "\"name\":\"Bash\",\"input\":{\"command\":\"grep -rn foo src/\",\"description\":\"foo 쓰는 자리 찾기\"}}]}}";
    try scanLine(allocator, line, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const hit = out.items[0];
    // 라벨의 대상은 **요약**이다(그 편이 한 줄에 읽기 좋다).
    try testing.expectEqualStrings("foo 쓰는 자리 찾기", line[hit.data_offset..][0.."foo 쓰는 자리 찾기".len]);
    // 그런데 펼침의 자리는 **명령**이다.
    try testing.expect(hit.cmd_rel != 0);
    try testing.expectEqualStrings("grep -rn foo src/", line[hit.cmd_rel..][0.."grep -rn foo src/".len]);
}

test "펼침 대상: 대상이 이미 명령이면 따로 안 든다 (AV3 적대적)" {
    // 같은 줄을 한 번 더 훑을 이유가 없다 — AV2 가 배운 그 비용이다. 0 은 「대상이 곧 명령」이라는 뜻이다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_C2\"," ++
        "\"name\":\"Bash\",\"input\":{\"command\":\"ls -la\"}}]}}";
    try scanLine(allocator, line, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 0), out.items[0].cmd_rel);
    try testing.expectEqualStrings("ls -la", line[out.items[0].data_offset..][0..6]);
}

test "펼침 대상: 한 줄에 호출이 둘이면 **각자 제 명령**을 가리킨다 (AV3 적대적)" {
    // ⚠️ **하나짜리 표본은 어긋남을 감춘다.** 호출이 하나뿐이면 자리를 잘못 골라도 「그 줄의 명령」이라
    // 우연히 맞는다. main 이 라벨에서 같은 이유로 레코드 범위를 닫았고(한 줄에 둘일 때 남의 값을 집던
    // 결함), 펼침의 자리도 그 범위를 지켜야 한다.
    const allocator = testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[" ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_E1\",\"name\":\"Bash\"," ++
        "\"input\":{\"command\":\"first cmd\",\"description\":\"첫째\"}}," ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_E2\",\"name\":\"Bash\"," ++
        "\"input\":{\"command\":\"second cmd\",\"description\":\"둘째\"}}]}}";
    try scanLine(allocator, line, 0, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    // 라벨은 각자의 요약이고,
    try testing.expectEqualStrings("첫째", line[out.items[0].data_offset..][0.."첫째".len]);
    try testing.expectEqualStrings("둘째", line[out.items[1].data_offset..][0.."둘째".len]);
    // 펼침 자리도 **각자의 명령**이다 — 둘 다 첫 명령을 가리키면 여기서 죽는다.
    try testing.expectEqualStrings("first cmd", line[out.items[0].cmd_rel..][0.."first cmd".len]);
    try testing.expectEqualStrings("second cmd", line[out.items[1].cmd_rel..][0.."second cmd".len]);
    // 그리고 id 도 각자 것이다(같은 규율의 다른 축 — 링크가 남의 결과를 집지 않는 근거다).
    try testing.expectEqualStrings("toolu_E1", line[out.items[0].id_rel..][0.."toolu_E1".len]);
    try testing.expectEqualStrings("toolu_E2", line[out.items[1].id_rel..][0.."toolu_E2".len]);
}
