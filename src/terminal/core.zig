const std = @import("std");
const builtin = @import("builtin");
const input = @import("input.zig");
const types = @import("types.zig");

// Agent observer가 fullscreen TUI의 trailing blank padding을 건너뛸 때 읽는 최대 행 수. 실제 UTF-8 복사 상한과
// 별개로 cell 탐색도 bounded해, 비정상적으로 큰 grid에서 한 번의 observer poll이 전체 화면을 훑지 않게 한다.
const recent_text_blank_scan_rows: usize = 256;
const osc = @import("osc.zig"); // OSC host-reply 핸들러(색·팔레트·클립보드·hyperlink·semantic) — 목적별 분리(구조와 파일 분리)
const parser = @import("parser.zig"); // VT 파서(write feed + escape/CSI/OSC/DCS/APC dispatch + UTF-8) — 목적별 분리
const screen = @import("screen.zig"); // 화면 storage + 활성 화면 연산(grid·cursor·scroll·print·resize·snapshot) — 목적별 분리
const selection = @import("selection.zig"); // 선택/검색/URL(화면을 읽는 상위 레이어) — 목적별 분리
const kitty = @import("kitty.zig"); // kitty graphics 본체(transmit·display·delete·view) — 목적별 분리
const input_report = @import("input_report.zig"); // 입력/이벤트 → host 바이트 인코딩(키·paste·focus·mouse) — 목적별 분리
// kitty graphics 저장 struct는 kitty.zig 소유(self-contained — Scrollback 선례). core는 별칭으로 필드 타입을 둔다.
const KittyGraphicsCommand = kitty.KittyGraphicsCommand;
const StoredPlacement = kitty.StoredPlacement;
const KittyImageStorage = kitty.KittyImageStorage;
const width = @import("../width.zig"); // Unicode 셀 폭은 중립 top-level 유틸로 이동(src/width.zig)
const CoreOwner = @import("core_owner.zig").CoreOwner; // core_mutex 재진입 추적(디버그 전용 안전망)

/// `std.atomic.Value`와 같은 인터페이스의 **비-atomic** 셀. wasm 타깃에서 `ObserverCell`이 이걸로 접힌다.
/// 오버플로는 `+%`로 감싼다 — 소비자가 `!=`만 보므로(아래) 랩어라운드가 의미를 깨지 않는다.
fn PlainValue(comptime T: type) type {
    return struct {
        raw: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .raw = value };
        }

        pub inline fn fetchAdd(self: *Self, operand: T, comptime _: std.builtin.AtomicOrder) T {
            const previous = self.raw;
            self.raw = previous +% operand;
            return previous;
        }

        pub inline fn load(self: *const Self, comptime _: std.builtin.AtomicOrder) T {
            return self.raw;
        }

        pub inline fn store(self: *Self, value: T, comptime _: std.builtin.AtomicOrder) void {
            self.raw = value;
        }
    };
}

/// `observer_generation`의 저장 셀. 네이티브는 atomic(리더 스레드가 쓰고 메인이 락 없이 읽는다 —
/// docs/io-render-threading.md), wasm은 비-atomic이다. 근거는 [wasm 이식성](../../docs/wasm-portability.md):
/// ⑴ wasm 모듈은 단일 스레드라(SharedArrayBuffer 없이 경쟁이 성립하지 않는다) atomic이 불필요하고,
/// ⑵ Zig 0.16은 wasm에서 64비트 atomic RMW를 거부한다(`expected 32-bit integer type or smaller`).
/// **폭을 u32로 좁히지 않는 이유**: 이 값은 `app/event_cursor.zig`의 u64 시퀀스 묶음(bell·clipboard)과
/// 함께 다니고 그 형제들은 대소 비교를 한다. 타깃마다 폭이 갈리면 그 계약이 깨진다.
/// 네이티브 기계어는 이 분기 전후로 **완전히 동일**하다(`__TEXT,__text` 해시 일치 — 위 문서 §5).
const ObserverCell = if (builtin.target.cpu.arch.isWasm())
    PlainValue(u64)
else
    std.atomic.Value(u64);

/// hover가 밑줄을 그릴 링크: 시작 anchor와 (공백 확장까지 반영한) 끝. `end`가 null이면 밑줄은 예전대로
/// anchor에서 토큰 경계까지 계산한다(OSC 8 명시 링크 등 토큰 경계를 못 잡는 경우).
pub const HoverLink = struct { anchor: types.SelectionPoint, end: ?types.SelectionPoint };

/// 열 수 있는 링크: 열 대상 텍스트(호출자 소유)와 그것이 차지한 **화면 범위**. 범위는 밑줄이 쓴다 —
/// 공백 든 경로는 토큰보다 넓어서, 밑줄을 토큰만큼만 그리면 "밑줄 밖을 눌러야 열리는" 상태가 된다.
pub const OpenableLink = struct {
    text: []u8,
    kind: selection.LinkKind,
    /// OSC 8 명시 링크처럼 토큰 경계를 못 잡는 경우 null(그때 밑줄은 예전대로 `urlSpanAtAbs`가 계산한다).
    bounds: ?selection.WordBounds,
};

/// 공백 든 경로를 찾을 때 붙여 볼 세그먼트 상한. `C:\Program Files\Common Files\x.dll`이 2개,
/// `/Users/John Smith/My Documents/a.txt`가 2개다 — 5면 현실 경로를 덮고, 최악 비용도 이동 간격의 2.4 %다.
const max_space_segments: usize = 5;

/// 연속으로 이만큼 실패하면 확장을 멈춘다. **1이면 안 된다** — 주 사례(`C:\Program Files\x.txt`)가
/// 첫 물음(`C:\Program`)에서 실패하고 두 번째에서 성공하기 때문이다. 2면 그 사례를 살리면서 평범한
/// 경로가 무는 헛 stat을 둘로 묶는다.
const max_consecutive_misses: usize = 2;

// 파일 존재검증의 Windows 갈래(`TerminalCore.pathExists`). CRT `_access`가 바이트를 ANSI 코드페이지로 읽어
// 비-ASCII 경로를 놓치므로 Win32의 UTF-16 API를 직접 부른다 — 이유와 실측은 그 함수의 doc에.
const invalid_file_attributes: u32 = 0xFFFF_FFFF;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;

/// 단말 자기식별의 단일 신원 출처. XTVERSION(CSI > q) 응답이 지금 이걸 쓰고, 이후 추가할 자체
/// terminfo 생성과 XTGETTCAP(DCS + q) 응답도 같은 값을 재사용한다 — 이름/버전이 채널마다 어긋나지
/// 않도록 한곳에서만 정의한다. 버전의 정식 단일 출처는 build.zig.zon의 `.version`이며, 지금은 둘 다
/// "0.0.0" placeholder다. build_options로 연결하면 drift가 사라지지만, 순수 VT core를 빌드 시스템에
/// 결합하지 않으려고(이식성·단위 테스트 격리) 지금은 상수로 둔다 — 릴리스가 생기면 이 값을 함께 올린다.
pub const terminal_name = "maru";
pub const terminal_version = "0.0.0";

/// terminfo 항목의 primary 이름. XTGETTCAP의 `TN`(terminal name) 캡 응답에 쓴다. XTVERSION의 자유형
/// 이름(`terminal_name` = "maru")과 달리, 이건 terminfo `TN`이라 `terminfo/maru.terminfo`의 primary
/// 이름과 **반드시 일치**해야 한다(Ghostty도 XTVERSION "ghostty" vs terminfo "xterm-ghostty"로 분리).
/// 그 파일을 바꾸면 이 값도 함께 바꾼다(단일 출처는 그 파일, 이 상수는 그 미러).
pub const terminfo_name = "xterm-maru";

/// mouse tracking 모드(DECSET 9/1000/1002/1003) — 어떤 마우스 이벤트를 앱에 리포트할지(상호 배타). 베이스: xterm
/// mouse tracking. none=꺼짐, x10=press만, normal=press+release, button=+버튼 눌린 채 drag, any=+모든 motion.
pub const MouseTracking = enum { none, x10, normal, button, any };
/// mouse 이벤트 인코딩(DECSET 1006 SGR / 1016 SGR-pixels / 기본 x10). 베이스: xterm. SGR은 좌표 무제한(>223 OK).
pub const MouseFormat = enum { x10, sgr, sgr_pixels, urxvt };

/// kitty keyboard protocol(progressive enhancement) flag(packed u5). disambiguate=모호한 키만 CSI u로 명확히,
/// report_events=key up/repeat, report_alternates=대체 키, report_all=모든 키 escape, report_associated=텍스트.
/// 비트 위치(disambiguate=1·report_events=2·report_alternates=4·report_all=8·report_associated=16)는 kitty
/// keyboard protocol 명세가 정한 progressive-enhancement 플래그 값이다. 기본 disabled(legacy 인코딩).
pub const KittyFlags = packed struct(u5) {
    disambiguate: bool = false,
    report_events: bool = false,
    report_alternates: bool = false,
    report_all: bool = false,
    report_associated: bool = false,

    pub const disabled: KittyFlags = .{};
    pub fn int(self: KittyFlags) u5 {
        return @bitCast(self);
    }
};
/// kitty flags의 set 연산 모드(CSI = flags ; mode u). 1=set(치환)·2=or(합집합)·3=not(차집합) — 베이스: kitty spec.
pub const KittySetMode = enum { set, @"or", not };
/// kitty flags 스택(CSI > flags u = push, CSI < n u = pop, CSI = flags;mode u = set). 활성 flags 하나와
/// 복원용 스택을 따로 둔다 — push는 현재 flags를 스택에 저장하고 새 flags로 진입하고, pop n은 n단을
/// 복원한다. kitty keyboard protocol은 스택 깊이/오버플로 동작을 규정하지 않으므로 maru가 한도를 정한다:
/// 한도(16) 초과 push는 가장 오래된 복원 지점을 버리고, 스택 높이를 넘는 pop은 비활성으로 떨군다(빈 스택은
/// disabled). 터미널 모드 스택은 보통 1~2단이라 한도 초과는 비현실적. 베이스: kitty keyboard protocol의
/// flag 스택(push/pop/set 의미만 명세; 자료구조는 maru 설계).
pub const KittyFlagStack = struct {
    const max_depth = 16;
    active: KittyFlags = .{},
    saved: [max_depth]KittyFlags = @splat(.{}),
    depth: usize = 0,

    pub fn current(self: KittyFlagStack) KittyFlags {
        return self.active;
    }
    pub fn set(self: *KittyFlagStack, mode: KittySetMode, v: KittyFlags) void {
        const cur = self.active.int();
        self.active = @bitCast(switch (mode) {
            .set => v.int(),
            .@"or" => cur | v.int(),
            .not => cur & ~v.int(),
        });
    }
    pub fn push(self: *KittyFlagStack, flags: KittyFlags) void {
        if (self.depth == max_depth) {
            // 한도 초과: 가장 오래된 복원 지점을 버리고 한 칸 당긴다.
            std.mem.copyForwards(KittyFlags, self.saved[0 .. max_depth - 1], self.saved[1..]);
            self.depth -= 1;
        }
        self.saved[self.depth] = self.active;
        self.depth += 1;
        self.active = flags;
    }
    pub fn pop(self: *KittyFlagStack, n: usize) void {
        if (n >= self.depth) {
            // 스택 높이 이상으로 pop하면 전부 비우고 비활성(빈 스택 pop은 disabled).
            self.depth = 0;
            self.active = .{};
            return;
        }
        for (0..n) |_| {
            self.depth -= 1;
            self.active = self.saved[self.depth];
        }
    }
};

/// DECSC/DECRC(ESC 7/8)·DECSET 1048/1049가 쓰는 저장 커서 상태. 화면(primary/alt)마다 하나씩 둔다.
pub const SavedCursor = struct {
    cursor: types.Cursor = .{},
    pen: types.Style = .{},
    pending_wrap: bool = false,
};

/// 활성 화면 grid(cells·wrapped·prompt_marks) + 스크롤백(sb)을 묶는 2단계 Screen struct(B-min). storage라
/// screen.zig 소유(Scrollback도 그 안에 귀속 — B2), core는 `screen`/`saved_screen` 필드로 보유. 행 push/get/
/// rewrap 등 연산은 free 함수가 self.screen.<field>(또는 self.screen.sb.<field>)를 직접 다룬다(struct는 데이터 그릇).
const Screen = screen.Screen;

/// grapheme_ids 해시맵의 키 컨텍스트 — cluster 본체([]u21)를 바이트로 해시·비교해 dedup한다.
/// link_ids(StringHashMap, []u8 키)의 []u21 판이다(같은 cluster를 한 번만 저장).
const GraphemeKeyContext = struct {
    pub fn hash(_: GraphemeKeyContext, key: []const u21) u64 {
        // **값 기반** 해시 — `sliceAsBytes([]u21)`는 u21의 4바이트 backing 중 상위 11 패딩 비트를
        // 같이 해시해서, 같은 값이라도 패딩(alloc 잔재)이 다르면 다른 해시가 나온다(eql은 값만 비교 →
        // "같은 키는 같은 해시" 계약 위반 → dedup이 새 entry를 또 만든다). 각 코드포인트를 u32로 넓혀
        // 정의된 바이트만 해시한다(eql과 일치).
        var h = std.hash.Wyhash.init(0);
        for (key) |cp| {
            const v: u32 = cp;
            h.update(std.mem.asBytes(&v));
        }
        return h.final();
    }
    pub fn eql(_: GraphemeKeyContext, a: []const u21, b: []const u21) bool {
        return std.mem.eql(u21, a, b);
    }
};

pub const TerminalCore = struct {
    allocator: std.mem.Allocator,
    size: types.Size,
    // 활성 화면 grid(cells·wrapped·prompt_marks)+스크롤백(sb)+커서 클러스터(cursor·pen·pending_wrap·last_print·
    // last_printed_cp) — Screen struct. 행/커서 연산은 self.screen.<field>로 접근(screen.zig 소유, Scrollback 선례).
    // alt 전환은 screen↔saved_screen 통째 swap이라 커서도 화면에 귀속된다(per-screen, §10.8). scroll region·모드·
    // tabstops는 두 화면 공유(global)라 core 잔류(Ghostty Terminal과 동형).
    screen: Screen = .{},
    // core_mutex(Surface 소유)를 잡는 스레드를 추적하는 디버그 전용 안전망. lock은 Surface.lockCore
    // 와 reader가 owner_dbg.lock/unlock으로만 잡아 재진입(self-deadlock)을 lock 전에 panic으로
    // 노출한다. release에선 @sizeOf 0(ABI 영향 없음). 단일 출처: src/terminal/core_owner.zig.
    owner_dbg: CoreOwner = .{},
    dirty: ?types.DirtyRegion = null,
    utf8_tail: [4]u8 = undefined,
    utf8_tail_len: usize = 0,
    // last_print·pen·cursor·pending_wrap·last_printed_cp는 커서 클러스터로 Screen에 귀속(per-screen, §10.8) —
    // self.screen.<field>로 접근한다.
    // VT escape 파서 상태기계. ground 외 상태에서는 byte를 escape sequence로 소비한다.
    parser: ParserState = .ground,
    // CSI 파라미터 누적 버퍼. 대부분의 시퀀스는 파라미터가 적으므로 작은 고정 크기로 충분하고,
    // 넘치면 무시한다(악성/비정상 입력 방어).
    csi_params: [max_csi_params]u16 = [_]u16{0} ** max_csi_params,
    csi_param_count: usize = 0,
    csi_has_digit: bool = false,
    // CSI의 private marker 바이트(0x3c-0x3f: '<','=','>','?'). 0이면 없음. xterm은 marker별로
    // 의미가 다르다 — DECSET/DECRST는 '?' 전용이고 '>'는 DA2/XTVERSION 등 별도 명령이다.
    csi_marker: u8 = 0,
    // CSI intermediate 바이트(0x20-0x2f, 예: DECSCUSR의 ' ', DECCARA의 '$'). 0이면 없음.
    // intermediate가 붙은 시퀀스는 같은 final이라도 다른 명령이므로 (intermediate, final) 튜플로
    // dispatch하고, 모르는 조합은 소비한다(VT500 파서 의미). 여러 개면 마지막 것만 기억한다
    // (실사용 시퀀스는 intermediate 1개).
    csi_intermediate: u8 = 0,
    csi_overflow: bool = false,
    // DECSTBM scroll region(top/bottom margin, 0-indexed inclusive). LF/IND/RI 스크롤은 이 구간
    // 안에서만 일어난다. 기본은 화면 전체 [0, rows-1]. init/resize에서 전체로 리셋한다. less/vim
    // 등이 상태줄을 고정하고 본문만 스크롤하는 데 쓴다.
    scroll_top: u16 = 0,
    scroll_bottom: u16 = 0,
    /// DECOM(origin mode, DECSET ?6). 켜지면 CUP/HVP의 row가 scroll region 상단 기준(1=region top)이고
    /// 커서가 region 안에 갇힌다. RIS·기본은 off(화면 절대 좌표). 좌우 margin이 없어 col은 영향 없다.
    origin_mode: bool = false,
    // alternate screen(DECSET 1049/47/1047). vim·less 같은 TUI가 전체 화면을 쓰고 종료 시 원래
    // 셸 화면을 복원하는 보조 버퍼다. 활성이면 saved_*에 primary 그리드가 보관돼 있고, alt 출력은
    // 스크롤백에 쌓이지 않으며 스크롤백 뷰포트도 잠긴다(표준 xterm 동작).
    alt_active: bool = false,
    // DECCKM(CSI ?1 h/l, application cursor keys). vim/less가 켜면 화살표 입력이 SS3(`ESC O A`)로
    // 인코딩돼야 한다. core는 모드만 추적하고, 인코딩은 input.encodeKey가 EncodeOptions로 받는다.
    application_cursor_keys: bool = false,
    // DECKPAM/DECKPNM(ESC =/ESC >, G10): application/numeric keypad 모드. 켜지면 numpad 키가 SS3(`ESC O p`..)로
    // 인코딩돼야 한다(DECCKM 화살표와 같은 결). core는 모드만 추적 — 실제 numpad 인코딩은 input 모델에 keypad 키
    // 변종 + Swift numpad keycode 감지가 전제라 후속(macOS는 numpad 드묾). RIS에서 off(numeric).
    application_keypad: bool = false,
    // alternate scroll(xterm DECSET 1007): alt screen에서 휠/트랙패드 스크롤을 화살표 키로 변환해
    // 프로그램에 보낸다(less/vim이 자체 스크롤). 스크롤백이 잠긴 alt에서 스크롤이 무반응이 되지
    // 않게 하는 표준 장치로, iTerm2/Terminal.app처럼 기본 켠다(프로그램이 ?1007l로 끌 수 있음).
    alternate_scroll: bool = true,
    // bracketed paste(DECSET 2004): 켜져 있으면 붙여넣기를 ESC[200~ ... ESC[201~로 감싸 보낸다.
    // zsh/vim/claude가 켜며, 붙여넣은 텍스트를 타이핑과 구분해(자동 들여쓰기·즉시 실행 방지) 처리한다.
    bracketed_paste: bool = false,
    // focus reporting(DECSET 1004): 켜지면 창 포커스 in/out을 CSI I / CSI O로 PTY에 리포트한다.
    // vim FocusGained/Lost·자동저장 등이 쓴다. 기본 off — 앱이 켠다(progressive; 끄면 무리포트).
    focus_events: bool = false,
    // mouse reporting(DECSET 9/1000/1002/1003): 켜지면 클릭/드래그/휠을 좌표와 함께 PTY로 리포트(셀렉션 대신).
    // 기본 none — 앱이 켠다. nvim/tmux/htop/lazygit 등이 쓴다. shift 누르면 셀렉션 override(8b platform 처리).
    mouse_tracking: MouseTracking = .none,
    mouse_format: MouseFormat = .x10,
    // synchronized output(DECSET 2026): 켜지면 frame 투영을 멈춰(hold) ESU(2026 reset)까지 출력을 한 frame으로
    // 묶는다 — nvim 화면 갱신 tearing/깜빡임 방지. 베이스: Ghostty(synchronized_output이면 render skip)·DEC 2026.
    sync_output: bool = false,
    // synchronized output(2026): 리더(parser.feed)가 처리한 ESU(reset=프레임 완성) 누적 횟수. shouldProjectFrame이
    // 직전 투영 이후 이 값이 늘었으면(esu_advanced) 완성 프레임을 flush한다 — per-tick 폴링이 flush 창(<tick)을
    // 놓쳐 완성 프레임을 timeout까지 막던 MISS 수정. always-on 증분(단순 +%=). 베이스: Ghostty는 리더가 ESU에서
    // 렌더를 트리거해 회피하지만, maru는 tick 폴링이라 ESU 누적 카운트를 edge로 소비해 같은 효과를 낸다.
    sync_esu_count: u64 = 0,
    // synchronized output(2026): 리더가 처리한 BSU(set=hold 시작) 누적 횟수. ESU 짝(sync_esu_count)과 함께 .sync
    // 관측 로거가 노출해 "리더가 처리한 transition vs 메인 per-tick 샘플링(sync_output)"의 갭을 본다 — maru ssh에서
    // SSH 바이트 fragmentation으로 sync 투영이 어긋나는(원격 bubbletea 깨짐, docs/io-render-present.md §11.6·§sync)
    // 미해결 이슈 추적용. always-on 증분(단순 +%=, 분기 비용 0).
    sync_bsu_count: u64 = 0,
    /// kitty keyboard protocol flag 스택(CSI > flags u=push / < n u=pop / = flags;mode u=set로 앱이 제어).
    /// 기본 비어 있음(current=disabled) → encodeKey가 legacy 인코딩. 베이스: kitty keyboard protocol spec.
    kitty_flags: KittyFlagStack = .{},
    // grapheme cluster mode(DECSET 2027, terminal-unicode-core): 앱이 "나도 grapheme 단위 너비를
    // 쓴다"고 합의하면 켠다. 켜지면 VS16(이모지 표현)·스킨톤·국기 같은 grapheme을 한 셀로 묶고
    // 너비를 EAW 대신 cluster 기준(❤️=2칸 등)으로 잰다 — 앱과 너비가 일치하므로 붙여넣기 redraw가
    // 안 깨지면서 풀사이즈로 그릴 수 있다. 기본 off면 EAW per-codepoint(레거시 앱 호환). 앱은
    // DECRQM(CSI ?2027$p)로 지원 여부를 먼저 묻는다 — Ghostty/xterm.js와 같은 opt-in 모델이다.
    grapheme_cluster_mode: bool = false,
    // DECTCEM(CSI ?25 h/l): 커서 표시. TUI가 화면을 그리는 동안 커서 깜빡임/잔상을 숨기려고 끈다.
    // snapshot/renderSnapshot이 내보내는 cursor.visible에 합성된다(내부 self.screen.cursor.visible은 불변).
    cursor_visible: bool = true,
    // DECSCUSR(CSI Ps SP q): 커서 모양과 깜빡임. vim이 모드별로 bar/block을 전환하는 표준 수단.
    cursor_shape: types.CursorShape = .block,
    cursor_blink: bool = true,
    // config `cursor.shape`가 정한 **기본** 커서 모양 — DECSCUSR 0(`CSI 0 SP q`, "터미널 기본으로")과 RIS가 여기로
    // 되돌아간다. 앱이 DECSCUSR 1..6으로 명시하면 그게 이기고(vim 모드별 bar/block 보존), 명시를 거둬들이면 사용자
    // 설정이 다시 보인다 — 베이스는 Ghostty `cursor-style` + `default_cursor_style`(같은 "설정=기본값" 모델).
    // app(createTerm chokepoint·config reload)이 setDefaultCursorShape로 주입한다. 원격 core는 host가 소유하므로
    // RuntimeConfig로 실어 보낸다(같은 값·같은 규칙 — 로컬/원격 동작 동일).
    default_cursor_shape: types.CursorShape = .block,
    // 앱이 DECSCUSR 1..6으로 모양을 **명시**했는가. config reload가 라이브 커서를 덮어쓸지 판정하는 단일 근거다 —
    // 명시 중이면(vim insert-mode bar 등) 새 기본값은 저장만 하고 화면은 안 건드린다(Ghostty `default_cursor` 동형).
    cursor_shape_overridden: bool = false,
    // alt 화면 동안 비활성 화면(primary)을 통째로 보관하는 슬롯 — grid(cells·wrapped·prompt_marks) + 스크롤백(sb)을
    // 한 Screen으로 묶어 alt 전환이 `self.screen ↔ saved_screen` struct 교환 한 번이 된다(B3). primary 활성 중엔
    // 빈 인스턴스(cells 등 &.{}, sb cap 0). "alt엔 스크롤백 없음"이 grid까지 타입으로 보장된다(architecture.md 2단계).
    // DECSC 슬롯(saved_cursor)도 커서와 함께 Screen에 귀속돼 swap을 탄다(per-screen, §10.8 B5) — 화면(primary/alt)
    // 마다 별도 슬롯이 by-construction으로 보장되므로(한 슬롯 공유 시 alt 안 ESC 7/8이 셸 커서를 덮던 문제 소멸)
    // 옛 saved_cursor_primary/alt 평평 필드는 self.screen.saved_cursor / self.saved_screen.saved_cursor가 대체한다.
    saved_screen: Screen = .{},
    // 각 CSI 파라미터가 ';'(새 파라미터)가 아니라 ':'(sub-parameter)로 들어왔는지 표시한다.
    // ITU colon 형식 38:2:colorspace:r:g:b는 38;2;r;g;b와 달리 colorspace 컴포넌트가 하나 더
    // 있어, 이 구분 없이는 RGB가 한 칸 밀린다.
    csi_subparam: [max_csi_params]bool = [_]bool{false} ** max_csi_params,
    // wrapped(soft-wrap 추적)·prompt_marks(행별 OSC 133 분류)는 활성 grid라 2단계 Screen struct로 이동
    // (self.screen.wrapped / self.screen.prompt_marks — 정의·주석은 screen.zig Screen).

    // 현재 활성 중인 semantic 영역(OSC 133 A→prompt, B→input, C→command, D→unknown). lineFeed가
    // 다음 행에 이 값을 전파해 여러 줄 프롬프트/출력이 전부 태깅된다.
    semantic_state: types.SemanticPrompt = .unknown,
    // 가장 최근에 끝난 명령의 종료코드(OSC 133 ; D ; <code>, 없으면 null). shell이 음수도 보낼 수
    // 있어 i32. 이후 단계가 프롬프트 거터에 ✓/✗로 투영한다.
    last_command_exit: ?i32 = null,
    // 셸 통합(OSC 133/7) 의미 이벤트 스트림 — 명령 라이프사이클 경계를 시간순으로 기록한다(관측
    // 가능성: 디버그 로그·테스트·후속 trace가 같은 데이터를 공유). OSC 파싱이 append하고 소비자가
    // drain/clear한다. 누구도 drain 안 해도 무한정 자라지 않게 cap(shell_events_cap)에서 멈추고
    // overflow 플래그를 세운다(드롭은 디버그 로그가 보고 — 조용한 손실 방지). 화면 상태가 아니라
    // 전이 스트림이라 RIS는 건드리지 않는다(프레임마다 drain되어 어차피 짧게 유지).
    shell_events: std.ArrayListUnmanaged(types.ShellEvent) = .empty,
    shell_events_overflow: bool = false,
    // 활성 화면 스크롤백 ring은 Screen으로 이동(self.screen.sb — B2). primary cap은 init이
    // `.screen = .{ … .sb = .{ .cap = default_max_scrollback } }`로 세팅. alt 보관분은 saved_screen.sb(B3).
    // EAW Ambiguous(동그란 번호 등)를 2칸으로 advance할지(text.ambiguous-width=wide). 기본 false(narrow — 정렬
    // 안전·Ghostty/xterm.js 호환). putCell이 셀 폭을 정할 때 width.cellWidthAmbiguous로 반영하므로 grid·커서·렌더가
    // 같은 폭을 본다(단일 출처). app_session이 loaded_config에서 set(max_scrollback과 같은 직접 대입 패턴).
    ambiguous_wide: bool = false,
    // 이모지 표현(base+VS16, 키캡 2️⃣ 등)을 mode 2027 합의가 없어도 풀사이즈 width 2로 승격할지(text.emoji-width=wide).
    // 기본 false(core 단독)지만 app_session이 config(기본 wide)에서 true로 켠다. **레퍼런스와 반대 선택이다** —
    // Ghostty는 2027이 꺼져 있으면 VS16을 셀에 붙이되 폭은 narrow로 두고(소스 확인), xterm.js도 grapheme 애드온을
    // 붙인 임베더에서만 2칸이다. 근거는 앱 쪽이다: 모던 TUI의 string-width 라이브러리가 2칸으로 세는데 그 TUI들이
    // 2027을 안 켠다. ❤️·2️⃣가 1칸에 욱여넣어져 작아지던 것을 푼다. grapheme_cluster_mode(2027)면 이 플래그와 무관하게 항상 승격.
    // 트레이드오프: zsh ZLE가 base+VS16을 1칸으로 가정하면 줄 편집이 어긋날 수 있어 narrow로 끌 수 있다(text.emoji-width).
    emoji_wide: bool = false,
    // 뷰포트: 바닥(0=활성 화면)에서 위로 스크롤한 줄 수. [0, sb_count] 범위. >0이면 화면 윗부분에
    // 스크롤백(과거)이 보이고 활성 화면 아랫부분은 가려진다. 과거를 보는 중 새 출력이 scroll되면
    // 같은 내용을 계속 보도록 함께 올린다(scroll-lock).
    view_offset: usize = 0,
    // 마우스 드래그 선택(anchor=누른 곳, head=현재 끝). 절대 행 좌표라 스크롤해도 내용을 따라간다.
    // 스크롤백 eviction(가득 찬 ring)·재-wrap·clear 때 보정/해제된다.
    selection_anchor: ?types.SelectionPoint = null,
    selection_head: ?types.SelectionPoint = null,
    // 블록(직사각형) 선택 모드. true면 anchor~head를 행 흐름이 아니라 [min_col,max_col]×[min_row,max_row]
    // 사각형으로 해석한다(Option+드래그 — iTerm2/Terminal.app 관례). selectionStart가 false로 리셋하고
    // setSelectionBlock(start 직후)이 켠다. selectionClear/RIS에서 해제.
    selection_block: bool = false,
    // OSC 8 하이퍼링크. URI는 link_store에 intern(중복 제거)하고 셀에는 id(인덱스+1)만 둔다.
    // pen_link는 현재 열린 링크 id — 링크가 열린 동안 출력되는 셀에 찍힌다. store는 세션 수명
    // 동안 유지된다(셀이 스크롤백에 남아 있는 한 URI도 살아 있어야 하므로 GC하지 않는다).
    link_store: std.ArrayListUnmanaged([]u8) = .empty,
    link_ids: std.StringHashMapUnmanaged(u32) = .empty,
    pen_link: u32 = 0,
    // grapheme cluster 본체 저장소(셀 base 뒤에 붙는 extra 코드포인트 배열). Cell.grapheme_id가
    // 인덱스+1로 가리킨다 — link_store/link_ids와 **완전 동형**의 "셀엔 id, 본체는 store, dedup" 패턴.
    // grapheme_ids로 같은 cluster를 한 번만 저장하므로(같은 '한'을 천 번 찍어도 1 entry) store는
    // 셀 수가 아니라 **distinct cluster 수**만큼만 큰다 — 악센트·NFD 음절·키캡처럼 반복되는 cluster의
    // per-cell 증가를 막는다. append-only(reset·deinit에서만 free)라 flat cells:[]Cell의 memcpy가
    // grapheme_id를 복사해도 dangling이 없다(link과 동일). 이 전역 dedup store가 메모리를 distinct
    // cluster 수로 bound하는 **standing 답**이다 — 화면에서 사라진 cluster까지 회수하는 page-local
    // **구조적 회수**는 활성 grid 페이징(§11 B)을 vehicle로 삼았으나 **B가 A2와 충돌해 불가**해져 보류다
    // (plans/page-aligned-storage.md §11.8 §595 정정 — 측정된 grapheme 메모리 병목 없음). 재개가
    // 필요하면 활성 grid를 안 건드리는 split 모델(스크롤백만 page-local)로 — 전역 refcount/GC는 flat
    // cells:[]Cell+memcpy 위에서 위험해 도입하지 않는다.
    grapheme_store: std.ArrayListUnmanaged([]u21) = .empty,
    grapheme_ids: std.HashMapUnmanaged([]const u21, u32, GraphemeKeyContext, std.hash_map.default_max_load_percentage) = .empty,
    // OSC 내용 축적 버퍼(동적 — apc_buffer와 동형). 고정 2048이던 시절 OSC 52 클립보드 쓰기가 한 문단
    // (base64 ~2KB)만 돼도 통째로 버려져 ssh+tmux/nvim 원격 복사가 조용히 실패했다 — 상한을 OSC 52 디코드
    // 상한이 통과 가능한 parser.max_osc_bytes로 올린다. 초과/OOM이면 osc_overflow로 dispatch에서 폐기하고
    // (악의적/거대 시퀀스 방어), 대용량 dispatch 뒤 용량은 반납한다(일상 OSC는 title/cwd/133 등 소형).
    osc_buffer: std.ArrayListUnmanaged(u8) = .empty,
    osc_overflow: bool = false,
    // OSC 52 대용량 허용 latch — 소형 상한(max_osc_small_bytes) 도달 시 접두("52;")를 **1회만** 판정해
    // 캐시한다. 이후 바이트는 startsWith 재실행 없이 이 값으로 대용량 수집 여부를 정한다(21MB 클립보드가
    // 파서 hot path에서 접두를 수천만 번 재비교하던 것 제거). OSC 시작(`]`)에서 리셋.
    osc_large_ok: bool = false,
    // G14 DCS(ESC P ... ST) 수집 버퍼. 현재 DECRQSS(`DCS $ q <req> ST`)만 처리하고 요청은 짧아 64B면 충분
    // (넘으면 overflow로 폐기). Sixel/DECDLD 등 큰 DCS는 미지원이라 소비만 한다(이 상태기계가 그 토대).
    dcs_buffer: [64]u8 = undefined,
    dcs_len: usize = 0,
    dcs_overflow: bool = false,
    // APC(ESC _ ... ESC \) 축적 버퍼. kitty graphics(`ESC _ G ...payload... ESC \`)용 — 첫 바이트
    // 'G'면 kitty command로 파싱한다. 단일 APC(한 청크) 한도; 넘치면 그 APC는 통째로 무시한다(chunked면
    // 진행 중 전송도 폐기). 베이스: kitty graphics protocol(APC payload), OSC 버퍼와 동형.
    // kitty graphics APC payload 누적 버퍼(동적). 베이스: Ghostty가 APC를 ArrayList+max_bytes로 받는 것
    // (graphics_command.zig)과 동형 — 단일 APC로 오는 큰 transmit(과거 고정 4096 초과 시 silent drop)을
    // 받기 위해 고정 배열 대신 동적으로. 상한은 chunked와 같은 max_kitty_chunk_bytes(폭주 방어). 초과/OOM이면
    // apc_overflow로 표시해 dispatch에서 폐기한다. RIS/destroy에서 비운다.
    apc_buffer: std.ArrayListUnmanaged(u8) = .empty,
    apc_overflow: bool = false,
    // kitty graphics chunked 전송(m=1) 누적 버퍼 — 여러 APC로 쪼개 온 base64 payload를 모은다. 첫 청크가
    // control(a/f/s/v/i/o)을 갖고(kitty_chunk_cmd), 이후 청크는 payload만 이어 붙인다. m=0에서 누적 base64를
    // 한 번에 디코드한다(각 청크 base64는 4의 배수라 이어 붙여 디코드해도 유효 — kitty 규약). 비어 있으면
    // chunking 비활성. 베이스: kitty graphics protocol(chunked transmission).
    kitty_chunk: std.ArrayListUnmanaged(u8) = .empty,
    kitty_chunk_cmd: ?KittyGraphicsCommand = null,
    // 셀 픽셀 크기(platform이 setCellMetrics로 주입, 폰트·DPI·resize 시 갱신). **kitty 자동 크기 이미지의
    // 커서 advance에만** 쓴다 — 그 외 픽셀↔셀 환산은 여전히 렌더러 책임(K1을 셀 픽셀 1쌍 보관으로만 완화).
    // 0이면 미보유(헤드리스 등) — 자동 크기 advance를 건너뛴다. 마우스 1016이 픽셀을 주입하는 것과 같은 결.
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    // OSC 10/11 색 질의 응답용 기본 전경/배경 색(theme). platform이 setDefaultColors로 주입(셀 메트릭과 같은
    // 결) — 코어는 Color.default 추상만 알아 실제 RGB를 받는다. 주입 전 기본값은 어두운 테마 근사.
    default_fg_rgb: types.Rgb = .{ .r = 0xcc, .g = 0xcc, .b = 0xcc },
    default_bg_rgb: types.Rgb = .{ .r = 0x10, .g = 0x10, .b = 0x10 },
    // OSC 10/11 색 설정 override(null = theme 기본 사용). OSC 10이 전경, 11이 배경을 덮고 OSC 110/111이 리셋한다.
    // setDefaultColors(theme를 매 tick 주입)와 별개 필드라 주입이 set 값을 지우지 않는다. 렌더러 default 색은
    // app이 `override orelse theme`로 wiring하고(OSC 4 팔레트와 같은 결 — 코어가 override 보관, app이 소비),
    // OSC 10/11 질의도 override를 우선 회신한다. RIS에서 null.
    default_fg_override: ?types.Rgb = null,
    default_bg_override: ?types.Rgb = null,
    // OSC 4 팔레트 override: 256색 각 인덱스의 앱 재정의(null = 기본 xterm256 팔레트). OSC 4로 설정/질의,
    // OSC 104로 리셋(인덱스 없으면 전부). 렌더러가 `.indexed` 색을 풀 때 이 표를 먼저 본다(app이
    // paletteOverride()를 CellColors.palette로 wiring — 코어는 셀 픽셀/렌더를 모르는 K1 경계 유지). RIS에서 전부 null.
    palette_override: [256]?types.Rgb = .{null} ** 256,
    // K1 경계 보강: 코어는 config palette base를 palette_override 옆 별도 레이어로 보관한다 — 렌더(metal_frame)와
    // OSC 4 query 응답이 같은 우선순위(override > config > xterm256)를 공유해 화면·보고가 일치한다. OSC 4가 없을 때의
    // ANSI 16색 base(theme.palette)를 platform이 setConfigPalette로 주입한다. RIS/OSC104는 override만 리셋(config base 유지).
    config_palette: [16]?types.Rgb = .{null} ** 16,
    // OSC 52 클립보드 쓰기 요청(디코드된 바이트, pending). platform이 정책(allow) 확인 후 drain → system clipboard.
    clipboard_write: std.ArrayListUnmanaged(u8) = .empty,
    // OSC 52 클립보드 쓰기가 크기 상한(max_clipboard_bytes/max_osc_bytes)을 넘어 **거부**됐다는 1회성 신호.
    // 옛날엔 조용히 버려 사용자가 "복사가 왜 안 되지"만 겪었다(무음 실패). platform이 매 tick takeClipboardWriteRejected로
    // drain해 notice 토스트로 표면화한다 — Ghostty의 무음 폐기를 넘는 "우아한 가시적 상한"(terminal-compatibility-policy.md §OSC52).
    clipboard_write_rejected: bool = false,
    // OSC 52 클립보드 **읽기**(`?` 쿼리) pending. true면 platform이 정책(osc52.read) 확인 후 시스템 클립보드를
    // 읽어 base64 OSC 52 응답을 PTY로 보낸다(F2-6). 코어는 쿼리 파싱만 — 클립보드는 OS 소유라 직접 안 읽는다(write 대칭).
    clipboard_read_pending: bool = false,
    // 그 읽기 쿼리의 target(Pc) 문자열(예: "c"/"p"/"" — 응답 OSC 52에 그대로 echo). owned 복사라 deinit에서 해제.
    clipboard_read_target: std.ArrayListUnmanaged(u8) = .empty,
    // OSC 9(iTerm2)·OSC 777(rxvt) 데스크톱 알림 pending. 코어는 title/body 파싱만 하고, platform이 매 tick drain해
    // 네이티브 알림(UNUserNotificationCenter)으로 띄운다(후속 PR). 한 tick에 여럿 오면 마지막만 남는다(드묾, 허용).
    // 알림은 transient 이벤트라 RIS 대상 아님(pending은 다음 tick에 drain되어 곧 사라진다). osc_overflow가 크기 방어.
    notification_pending: bool = false,
    // 일반 OSC의 2 KiB 수집 상한에서 notify payload가 폐기됐다는 one-shot 신호. host가 이를
    // bounded drop counter로 옮겨 악의적/과대 알림이 무음 재시도되거나 PTY 수명을 깨지 않게 한다.
    notification_write_rejected: bool = false,
    notification_generation: u64 = 0,
    notification_title: std.ArrayListUnmanaged(u8) = .empty,
    notification_body: std.ArrayListUnmanaged(u8) = .empty,
    // ConEmu OSC 9;4 progress의 최신 payload. 에이전트 관측기가 터미널이 이미 받은 공개 프로토콜 신호를
    // 읽을 뿐이며, 알림으로 발사하지 않는다. bounded OSC parser가 입력 크기를 제한하고 마지막 값만 보관한다.
    agent_progress: std.ArrayListUnmanaged(u8) = .empty,
    // G3 charset: G0/G1 G-set 지정과 GL 호출. `ESC ( <f>`→G0, `ESC ) <f>`→G1(f='0'=dec_special·'B'=ascii).
    // SI(0x0f)→GL=G0, SO(0x0e)→GL=G1. print 시 GL의 charset으로 codepoint를 변환한다. RIS에서 전부 초기화.
    charset_g0: Charset = .ascii,
    charset_g1: Charset = .ascii,
    charset_gl: u1 = 0, // 0=G0(SI), 1=G1(SO)
    // ESC <intermediate>(0x20..0x2f)의 intermediate 바이트. escape_intermediate 상태가 final과 함께 해석한다
    // (예: `ESC ( 0`이면 intermediate='(' final='0'). 0이면 진행 중 아님.
    escape_intermediate_byte: u8 = 0,
    // G4 동적 탭스톱(col별 true=탭스톱). 기본은 8칸마다(col%8==0). HTS(ESC H)가 set, TBC(CSI g)가 clear,
    // CBT(CSI Z)가 역방향 이동. 길이는 cols와 맞춘다(resize가 재구성, OOM이면 isTabstop이 8칸 기본으로 폴백).
    tabstops: []bool = &.{},
    // G12 BEL(0x07) pending. platform이 매 tick takeBell로 drain해 시스템 벨(NSSound.beep)을 울린다.
    // bool로 합쳐 한 tick에 BEL이 쏟아져도 beep는 최대 1회(벨 폭주 방지). transient라 RIS 대상 아님.
    bell_pending: bool = false,
    // G6 IRM(CSI 4 h/l): insert mode. 켜지면 출력 글자가 커서 위치에 삽입(오른쪽 밀기)된다(덮어쓰기 아님). RIS off.
    insert_mode: bool = false,
    // G8 DECAWM(CSI ?7 h/l): autowrap. 기본 on(마지막 칸 넘침 시 다음 줄로 wrap). off면 마지막 칸에서 덮어쓴다. RIS on.
    autowrap: bool = true,
    // G9 DECSCNM(CSI ?5 h/l): 화면 반전. 켜지면 렌더러가 모든 셀의 전경/배경을 전역 스왑한다(app이 reverseScreen()을
    // CellColors.screen_reverse로 wiring, clear color도 전경색으로). 코어는 셀 색을 안 바꾸고 플래그만 — K1 경계. RIS off.
    reverse_screen: bool = false,
    /// kitty graphics 이미지 저장소(transmit된 이미지, image_id→픽셀 버퍼). 렌더는 후속.
    kitty_images: KittyImageStorage = .{},
    /// kitty graphics placement(표시 중인 이미지 인스턴스) 목록. (image_id, placement_id)로 식별 —
    /// 같은 키 재요청은 교체한다. anchor는 절대 행(스크롤백 0..sb_count-1, 이어서 활성 화면)이라 selection/
    /// find와 같은 좌표계로 스크롤·eviction에 따라 보정된다(shiftPlacementsForEviction). 상한
    /// (max_kitty_placements)으로 악의적 대량 placement를 막는다 — 이미지 320MB 한계·APC 버퍼 한계와 같은
    /// 결의 방어선이다. K1(현재)은 저장/노출/생애주기(코어)까지 — 화면 렌더는 후속 K-단계.
    kitty_placements: std.ArrayListUnmanaged(StoredPlacement) = .empty,
    /// renderSnapshot이 placement를 뷰포트 상대 KittyPlacement로 환산해 담는 재사용 버퍼(placement가
    /// 있을 때만 lazy 할당, viewport_cells와 같은 규율). 없으면 비어 있어 일반(placement 없는) 경로는
    /// 추가 비용이 없다.
    placement_views: []types.KittyPlacement = &.{},
    /// renderSnapshot이 저장된 이미지를 KittyImageView로 빌려 담는 재사용 버퍼(이미지가 있을 때만 lazy
    /// 할당). 픽셀은 복사하지 않고 storage 버퍼를 가리키는 zero-copy다(id/치수/generation/픽셀 포인터만).
    image_views: []types.KittyImageView = &.{},
    // OSC 7: 셸이 보고한 현재 작업 디렉터리(cwd). VTE(GNOME)가 정의한 사실상 표준 — 형식은
    // `OSC 7 ; file://<host>/<percent-encoded path> ST`이고 iTerm2/Terminal.app/kitty/WezTerm이
    // 채택했다(ECMA-48 아님). 디코드한 path를 core가 소유한다. 창 제목 등이 읽는다. 셸 상태라 화면
    // clear엔 안 지우고 RIS에서만 지운다. 한 번도 안 받았으면 null(빈 cwd).
    cwd: ?[]u8 = null,
    // 같은 OSC 7의 **authority(host)**. 예전엔 버렸으나(로컬 단일 호스트 가정) 그러면 원격 셸이 보고한
    // 경로가 로컬 경로와 구분되지 않아, 폴더줄이 사라지거나 없는 디렉터리로 spawn을 시도한다
    // (docs/ssh-integration.md §9). path와 **함께** 갱신해 둘이 어긋나지 않게 한다 — host만 남고 path가
    // 옛 값이면 로컬 경로에 원격 host가 붙는 최악의 오표시가 된다. 빈 authority(`file:///path`)는 VTE
    // 규약상 localhost이고 여기서는 null로 둔다(로컬과 같은 취급). 로컬 여부 판정은 hostIsLocal.
    cwd_host: ?[]u8 = null,
    // maru ssh 전용 OSC(5379)로 받은 원격 세션의 목적지(dest). maru ssh 래퍼가 exec 직전 emit하면
    // (docs/ssh-integration.md §4) Maru가 저장해 "이 세션은 maru ssh 원격, 목적지=dest"임을 안다 — dest로
    // cli.ssh.controlSocketPath를 계산해 드롭 파일을 control socket으로 업로드하는 토대(3단계)다. cwd와
    // 달리 RIS에서 유지한다: ssh 연결은 RIS(터미널 리셋)와 무관하고 maru ssh가 세션 시작에 한 번만
    // 보고하므로(재보고 없음) 리셋하면 영영 잃는다. destroy(deinit)에서만 해제. 로컬/미수신이면 null.
    ssh_remote_dest: ?[]u8 = null,
    // OSC 0/2: 프로그램이 지정한 창 제목(xterm ctlseqs — OSC 0=아이콘+제목, OSC 2=제목; OSC 1=아이콘만
    // 무시). core가 소유한다. 셸/앱이 지정하면 창 제목에 우선 쓰고, 없으면 cwd basename으로 폴백한다
    // (windowTitle). 빈 제목(OSC 2 ; ST)은 해제(null)로 본다. RIS에서 공장 초기화. 그리드엔 안 보인다.
    title: ?[]u8 = null,
    // windowTitle() 결과가 바뀔 때(title 또는 cwd 변경)마다 리더가 +1하는 generation(P4-1, docs/plans/io-render-threading.md §12).
    // 메인의 syncAutoTitles가 **lock 없이** 이 값을 읽어 직전 반영 값과 다를 때만 lock+windowTitle 복사한다 — 매 tick 전-Term
    // lock을 제목이 실제 바뀐 term에만 국한(대부분 tick lock 0회). ordering은 `.monotonic`으로 충분(변경-감지 카운터일 뿐;
    // title/cwd 버퍼는 core_mutex 아래에서만 읽어 mutex가 가시성 보장 — bumpTitleGeneration 참조, code-review [7]).
    // windowTitle이 title??cwd_basename이라 title/cwd 중 하나만 바뀌어도 bump하되, 각 setter가 값 동일 시 bump를 생략한다(P4-1).
    title_generation: std.atomic.Value(u32) = .init(0),
    // PTY write가 들어올 때마다 증가하는 observer용 sequence. 화면 tail/title/progress가 그대로인 안정 idle Term은
    // 이 값으로 재직렬화를 건너뛴다. atomic이라 tick이 lock 전에 값만 싸게 확인할 수 있다.
    observer_generation: ObserverCell = .init(0),
    // 스크롤된(view_offset>0) 상태의 렌더용 합성 버퍼(rows×cols). renderSnapshot이 뷰포트 윈도를
    // 여기에 합성한다. view_offset==0이면 안 쓰므로 lazy 할당한다(스크롤할 때만 메모리 사용).
    viewport_cells: []types.Cell = &.{},
    // 스크롤된 뷰포트의 행별 OSC 133 태그(viewport_cells와 병렬, rows 길이). renderSnapshot이
    // 보이는 행에 맞춰 합성한다. view_offset==0이면 안 쓰므로 lazy 할당한다.
    viewport_prompt_marks: []types.RowPrompt = &.{},
    // resize reflow가 출력 행을 누적하는 재사용 스크래치(grow-only, rows×cols). 매 resize에
    // ArrayList를 새로 키우지 않도록 struct에 들고 다닌다 — core_resize_loop perf 예산을 지키려면
    // alloc churn을 없애야 한다(되돌린 구현이 ArrayList realloc으로 예산을 깼다).
    reflow_cells: []types.Cell = &.{},
    reflow_wrapped: []bool = &.{},
    // reflow가 산출 행별로 OSC 133 태그를 누적하는 스크래치(reflow_wrapped와 병렬, 같은 cap_rows).
    // 논리 줄 하나의 모든 행은 같은 분류라, 출력 행이 어느 옛 행에서 나왔든 그 옛 행의 태그를 그대로
    // 옮긴다 — resize 후에도 프롬프트/입력/출력 분류가 보존된다(PR1의 .unknown 한계 제거).
    reflow_prompt_marks: []types.RowPrompt = &.{},
    // 터미널이 호스트로 돌려보낼 응답(CPR 커서 위치 보고, DSR 상태 등). write() 중 query를 만나면
    // 여기에 쌓이고, app 레이어가 매 write 후 drain해 PTY로 되쓴다(프로그램이 입력처럼 읽는다).
    // zsh 등은 SIGWINCH redraw 때 CSI 6n으로 커서를 묻는데, 응답이 없으면 redraw가 어긋난다.
    response: std.ArrayList(u8) = .empty,

    pub const ParserState = enum { ground, escape, escape_intermediate, csi, osc, osc_escape, apc, apc_escape, dcs, dcs_escape };

    /// G3 charset 지정(94-char G-set). 구형 TUI가 `ESC ( 0`(G0=DEC special graphics)으로 지정하고 SO/SI로
    /// 호출해 box-drawing(┌─┐ 등)을 ASCII 코드포인트(lqk 등)로 보낸다. `.ascii`는 무변환, `.dec_special`은
    /// 0x60..0x7e를 box 문자로 변환. 베이스: VT100 special graphics·xterm ctlseqs(Ghostty `charsets.zig` 동작 비교).
    pub const Charset = enum { ascii, dec_special };

    pub const max_csi_params = 16; // parser(applySgr·csiNextParam)·screen·core가 cross-file 참조 — pub

    const default_max_scrollback = 1000;
    /// 한 세션이 동시에 가질 수 있는 kitty graphics placement 상한 — maru가 정한 실용 값이다(kitty
    /// 명세는 상한을 규정하지 않는다). (image_id, placement_id) 키 교체로 대부분 자연히 묶이지만, 한
    /// 이미지에 placement_id를 무한히 바꿔 보내는 폭주를 막는 방어선이다(이미지 320MB·APC 버퍼 한계와
    /// 같은 결). 보통 화면에 떠 있는 이미지는 한 자릿수~수십이라 1024는 충분히 여유롭다.
    pub const max_kitty_placements = 1024; // kitty.zig(addOrReplacePlacement)가 core.TerminalCore.로 cross-file 참조 — pub
    /// chunked(m=1) 전송에서 누적할 수 있는 base64 payload 상한 — 악의적 m=1 무한 전송의 메모리 폭주를
    /// 막는 방어선(이미지 320MB·APC 4096·placement 1024 한계와 같은 결). 디코드된 이미지는 320MB로 따로
    /// 제한되므로, base64 오버헤드(~4/3)를 감안해 480MB로 둔다. 초과하면 그 chunked 전송을 폐기한다.
    pub const max_kitty_chunk_bytes: usize = 480 * 1000 * 1000; // parser.dispatchApc도 참조(cross-file) — pub
    // OSC 52 클립보드 쓰기 상한(max_clipboard_bytes)은 osc.zig로 이동(clipboard 핸들러 전용).

    pub fn init(allocator: std.mem.Allocator, size: types.Size) !TerminalCore {
        const grid = clampGridSize(size);
        const cells = try allocator.alloc(types.Cell, cellCount(grid));
        errdefer allocator.free(cells);
        @memset(cells, .{});
        const wrapped = try allocator.alloc(bool, grid.rows);
        errdefer allocator.free(wrapped);
        @memset(wrapped, false);
        const prompt_marks = try allocator.alloc(types.RowPrompt, grid.rows);
        errdefer allocator.free(prompt_marks);
        @memset(prompt_marks, .{});
        const tabstops = try allocator.alloc(bool, grid.cols);
        errdefer allocator.free(tabstops);
        for (tabstops, 0..) |*t, c| t.* = (c % 8 == 0); // 기본 탭스톱: 8칸마다(col 0,8,16,…)

        return .{
            .allocator = allocator,
            .size = grid,
            // sb.arena_alloc을 core 일반 allocator로 둔다(기본 page_allocator override) — 테스트가 testing.allocator를
            // 쓰면 cell arena도 leak 추적된다. production은 app_session이 setScrollbackArena(page_allocator)로 교체(§11 P4).
            .screen = .{ .cells = cells, .wrapped = wrapped, .prompt_marks = prompt_marks, .sb = .{ .cap = default_max_scrollback, .arena_alloc = allocator } },
            .tabstops = tabstops,
            .dirty = fullDirty(grid),
            .scroll_bottom = grid.rows - 1,
        };
    }

    /// intern된 OSC 8 URI 저장소를 비운다(RIS 등 하드 리셋 — 이후 셀은 어차피 지워져 링크 id가
    /// 가리킬 대상이 없다). pen_link도 0으로.
    fn clearLinkStore(self: *TerminalCore) void {
        for (self.link_store.items) |uri| self.allocator.free(uri);
        self.link_store.clearRetainingCapacity();
        self.link_ids.clearRetainingCapacity();
        self.pen_link = 0;
    }

    /// RIS(ESC c) 하드 리셋: 화면을 비우고 스크롤백·선택·링크 저장소를 지우고 pen·모드를
    /// 공장 초기 상태로 되돌린다(VT100 RIS 의미론 근사). alt 화면이면 primary로 복귀한다.
    /// RIS(ESC c) 하드 리셋. parser.handleEscapeByte(ESC c)가 cross-file 호출 — pub.
    pub fn fullReset(self: *TerminalCore) void {
        if (self.alt_active) screen.leaveAltScreen(self);
        @memset(self.screen.cells, .{});
        @memset(self.screen.wrapped, false);
        @memset(self.screen.prompt_marks, .{});
        self.semantic_state = .unknown;
        self.last_command_exit = null;
        screen.clearScrollback(self); // sb 비우기 + 선택 해제
        self.clearLinkStore();
        self.clearGraphemeStore(); // 화면·스크롤백이 모두 비워져 grapheme_id가 가리킬 셀이 없다
        const had_title_or_cwd = self.cwd != null or self.title != null; // 지울 게 있었을 때만 bump(code-review [0])
        if (self.cwd) |c| { // OSC 7 cwd도 공장 초기화(셸이 다음 프롬프트에 다시 보고)
            self.allocator.free(c);
            self.cwd = null;
        }
        if (self.cwd_host) |h| { // host는 cwd와 한 쌍이라 반드시 함께 지운다(남으면 로컬 경로에 원격 host가 붙는다)
            self.allocator.free(h);
            self.cwd_host = null;
        }
        if (self.title) |t| { // OSC 0/2 창 제목도 공장 초기화(xterm RIS가 제목을 리셋하는 의미론)
            self.allocator.free(t);
            self.title = null;
        }
        if (had_title_or_cwd) self.bumpTitleGeneration(); // 지운 게 있어 windowTitle 결과가 바뀔 때만 재sync 유도(P4-1)
        self.screen.cursor = .{};
        self.screen.pen = .{};
        self.screen.pending_wrap = false;
        self.screen.last_print = null;
        // RIS는 DECSC 저장 슬롯도 공장 초기화한다(이후 DECRC/CSI u는 home 복원). 베이스: VT100 RIS = power-on
        // 상태 + Ghostty Screen.reset()이 saved_cursor=null. alt는 위 leaveAltScreen으로 이미 폐기됐으니 활성
        // (primary) 슬롯만 비우면 된다. (per-screen saved_cursor, §10.8 B5 — 옛 평평 슬롯 시절엔 미초기화였다.)
        self.screen.saved_cursor = .{};
        self.scroll_top = 0;
        self.scroll_bottom = self.size.rows - 1;
        self.cursor_visible = true; // DECTCEM(25) — 입력 모드가 아니라 화면 표시라 fullReset에 남긴다.
        // DECSCUSR도 공장 초기화 = **사용자 config 기본**(xterm RIS가 커서 스타일을 기본으로 되돌리는 것과 같다).
        // 프로그램의 override를 거둬들이는 것이므로 DECSCUSR 0과 같은 경로를 쓴다(기본 모양 단일 출처).
        screen.setCursorStyle(self, 0);
        self.sync_output = false; // 2026 동기 출력 — 입력 모드가 아니라 렌더 타이밍이라 fullReset에 남긴다.
        // 입력 인코딩 모드(application_cursor_keys/keypad·bracketed_paste·focus_events·mouse_tracking·
        // mouse_format·kitty_flags)는 resetInputModes가 단일 출처로 끈다 — 메뉴 Reset과 같은 코드를 공유(중복 제거).
        self.resetInputModes();
        self.kitty_images.clear(self.allocator); // RIS는 전송된 kitty graphics 이미지를 전부 비운다
        self.kitty_placements.clearRetainingCapacity(); // placement도 함께 비운다
        parser.abortKittyChunk(self); // 진행 중이던 chunked 전송도 폐기(parser 소유)
        parser.reclaimOscBuffer(self); // 방어적 백스톱 — RIS가 OSC 수집 잔재를 남기지 않게(다른 파서 버퍼 정리와 일관)
        self.grapheme_cluster_mode = false;
        self.charset_g0 = .ascii; // G3 charset도 공장 초기화(G0/G1 ascii, GL=G0).
        self.charset_g1 = .ascii;
        self.charset_gl = 0;
        screen.resetTabstops(self); // G4 탭스톱도 8칸 기본으로 공장 초기화(xterm RIS).
        self.insert_mode = false; // G6 IRM도 off로 복원.
        self.autowrap = true; // G8 DECAWM도 on(기본)으로 복원.
        self.screen.last_printed_cp = 0; // G5 REP 직전 글자도 비운다.
        self.reverse_screen = false; // G9 DECSCNM도 off(정상)로 복원.
        @memset(&self.palette_override, null); // OSC 4 팔레트 재정의도 공장 초기화(xterm RIS가 팔레트를 리셋).
        self.default_fg_override = null; // OSC 10/11 전경/배경 색 설정도 공장 초기화(theme 기본 복귀).
        self.default_bg_override = null;
        self.agent_progress.clearRetainingCapacity(); // 이전 프로그램의 progress를 상태 근거로 재사용하지 않는다.
        self.alternate_scroll = true; // DEC 1007 공장 기본값(켜짐) — 프로그램이 끈 뒤 RIS면 복원.
        self.origin_mode = false; // DECOM도 공장 기본(off — 화면 절대 좌표)으로 복원.
        self.dirty = fullDirty(self.size);
    }

    /// 입력 인코딩에 영향을 주는 사적 모드만 공장 초기화한다(화면·스크롤백·커서·pen은 보존).
    /// ssh 너머 TUI가 focus(1004)/mouse(1000·1002·1003)/kitty keyboard 모드를 켠 채 SIGKILL로
    /// 비정상 종료해 정리 시퀀스를 못 보내면, 잔류 모드 탓에 raw 셸에서 포커스/마우스마다 CSI I·
    /// 좌표가 흘러나가 입력이 오염된다. 이 함수는 그 잔류만 끊고 보이는 내용은 그대로 둔다 —
    /// fullReset(RIS)의 비파괴 변형으로, 메뉴 "Reset"이 호출한다(셸 통합 precmd 리셋의 백업 경로).
    /// bracketed_paste·application_cursor_keys도 끄지만, zsh zle이 다음 줄에 재설정하므로 안전하다.
    pub fn resetInputModes(self: *TerminalCore) void {
        self.application_cursor_keys = false; // DECCKM(1) — 방향키 SS3 인코딩 복원
        self.application_keypad = false; // DECKPAM — keypad numeric 복원
        self.bracketed_paste = false; // 2004 — 붙여넣기 래핑 해제(셸 zle이 다음 줄 재설정)
        self.focus_events = false; // 1004 — 포커스 CSI I/O 중단
        self.mouse_tracking = .none; // 9/1000/1002/1003 — 마우스 리포트 중단
        self.mouse_format = .x10; // 1006/1015/1016 — 마우스 인코딩 기본 복원
        self.kitty_flags = .{}; // kitty keyboard 스택·플래그 전부 비움
    }

    pub fn deinit(self: *TerminalCore) void {
        if (self.cwd) |c| self.allocator.free(c);
        if (self.cwd_host) |h| self.allocator.free(h);
        if (self.ssh_remote_dest) |d| self.allocator.free(d);
        if (self.title) |t| self.allocator.free(t);
        self.shell_events.deinit(self.allocator);
        for (self.link_store.items) |uri| self.allocator.free(uri);
        self.link_store.deinit(self.allocator);
        self.link_ids.deinit(self.allocator);
        for (self.grapheme_store.items) |g| self.allocator.free(g);
        self.grapheme_store.deinit(self.allocator);
        self.grapheme_ids.deinit(self.allocator);
        self.allocator.free(self.screen.cells);
        if (self.screen.wrapped.len > 0) self.allocator.free(self.screen.wrapped);
        if (self.screen.prompt_marks.len > 0) self.allocator.free(self.screen.prompt_marks);
        if (self.tabstops.len > 0) self.allocator.free(self.tabstops);
        if (self.saved_screen.cells.len > 0) self.allocator.free(self.saved_screen.cells);
        if (self.saved_screen.wrapped.len > 0) self.allocator.free(self.saved_screen.wrapped);
        if (self.saved_screen.prompt_marks.len > 0) self.allocator.free(self.saved_screen.prompt_marks);
        self.screen.sb.deinit(self.allocator);
        self.saved_screen.sb.deinit(self.allocator); // alt 중 destroy면 primary 스크롤백이 여기 보관돼 있다
        if (self.viewport_cells.len > 0) self.allocator.free(self.viewport_cells);
        if (self.viewport_prompt_marks.len > 0) self.allocator.free(self.viewport_prompt_marks);
        if (self.reflow_cells.len > 0) self.allocator.free(self.reflow_cells);
        if (self.reflow_wrapped.len > 0) self.allocator.free(self.reflow_wrapped);
        if (self.reflow_prompt_marks.len > 0) self.allocator.free(self.reflow_prompt_marks);
        self.response.deinit(self.allocator);
        self.kitty_images.deinit(self.allocator);
        self.kitty_placements.deinit(self.allocator);
        self.kitty_chunk.deinit(self.allocator);
        self.apc_buffer.deinit(self.allocator);
        self.osc_buffer.deinit(self.allocator);
        self.clipboard_write.deinit(self.allocator);
        self.clipboard_read_target.deinit(self.allocator);
        self.notification_title.deinit(self.allocator);
        self.notification_body.deinit(self.allocator);
        self.agent_progress.deinit(self.allocator);
        if (self.placement_views.len > 0) self.allocator.free(self.placement_views);
        if (self.image_views.len > 0) self.allocator.free(self.image_views);
        self.* = undefined;
    }

    /// 스크롤백에 보관된 행 수.
    pub fn scrollbackLen(self: *const TerminalCore) usize {
        return self.screen.sb.count;
    }

    /// primary 스크롤백의 용량(config scrollback.lines). 용량을 화면당 Scrollback.cap에 두는 건
    /// 의도적이다 — 이 per-screen 저장이 "alt=cap0" 불변식을 만들고, 그 불변식이 pushScrollback·
    /// scrollbackLen의 alt 무동작을 분기 없이 떠받친다(cap을 TerminalCore로 끌어올리면 pushScrollback에
    /// alt_active 가드가 되살아난다). alt 중에는 활성 sb가 빈(cap=0) 인스턴스라 config 값은 보관
    /// 슬롯(primary)에서 읽는다.
    pub fn maxScrollback(self: *const TerminalCore) usize {
        return if (self.alt_active) self.saved_screen.sb.cap else self.screen.sb.cap;
    }

    /// scrollback.lines config를 반영한다(런타임 reload 포함). 화면 단위 정책이라 활성 화면과 무관하게
    /// **항상 primary 스크롤백**에 적용한다(alt의 cap=0 불변식 유지 — 데이터 모델 보정이 아니라 config
    /// 라우팅). setCap이 ring을 새 cap으로 재구성하므로 변경이 즉시 반영되고(상향=더 보관, 하향=즉시
    /// 트림+메모리 회수) cap/ring.len 불일치(rewrap OOB의 원인)가 생기지 않는다.
    ///
    /// 하향이 가장 오래된 행을 버리면 그만큼 abs 좌표(선택·placement·view_offset)를 당긴다(eviction과
    /// 동일 규율). **단 활성 화면 스크롤백을 트림했을 때만** 보정한다 — alt 중에는 target이 parked
    /// primary(saved_sb)라 활성 alt 화면의 좌표와 무관하다. alt에서 그대로 보정하면 alt 화면에서 생성된
    /// (alt-space) kitty placement가 primary의 drop 수만큼 잘못 시프트/제거된다. alt 중 트림도 메모리는
    /// 회수하되 활성 좌표는 건드리지 않는다(선택은 alt 진입 시 해제·view_offset은 0이라 어차피 무동작).
    pub fn setMaxScrollback(self: *TerminalCore, lines: usize) void {
        const target = if (self.alt_active) &self.saved_screen.sb else &self.screen.sb;
        const dropped = target.setCap(self.allocator, lines);
        if (dropped > 0 and !self.alt_active) { // 활성 primary를 트림했을 때만 좌표 보정
            self.shiftCoordsForEviction(dropped); // 선택(걸리면 해제)·placement anchor를 dropped만큼 당김
            const old_offset = self.view_offset;
            self.view_offset = @min(self.view_offset, self.screen.sb.count); // 버린 과거를 가리키지 않게
            // 뷰가 실제로 움직였을 때만 리페인트한다 — 라이브 바닥(view_offset==0)에서 화면 밖 과거를
            // 버리면 보이는 내용은 그대로라 전체 dirty가 불필요하다.
            if (self.view_offset != old_offset) self.dirty = fullDirty(self.size);
        }
    }

    /// 스크롤백 cell arena의 backing allocator를 교체한다(§11 P4). production은 startup에 page_allocator
    /// (mmap/VirtualAlloc — demand-commit + 콜드 OS swap)를 넣는다. **반드시 스크롤백 페이지가 0개일 때(첫 출력
    /// 전) 호출**해야 한다 — 옛 arena로 잡힌 cells를 새 arena로 realloc/free하면 cross-allocator mismatch다. 따라서
    /// live 행(count)뿐 아니라 **pool에 회수된 페이지까지** 없어야 한다(clear/setCap(0)는 count=0이어도 pool에 옛
    /// arena 페이지를 남기므로 — P4 리뷰). primary 슬롯에 적용(startup은 항상 비-alt). 미호출 시 init 기본(일반 alloc).
    pub fn setScrollbackArena(self: *TerminalCore, arena: std.mem.Allocator) void {
        // 옛 arena로 잡힌 페이지가 pages·pool 어디에도 없어야 안전하게 교체 가능(arena mismatch 방지).
        std.debug.assert(self.screen.sb.pages.items.len == 0 and self.screen.sb.pool.items.len == 0);
        std.debug.assert(self.saved_screen.sb.pages.items.len == 0 and self.saved_screen.sb.pool.items.len == 0);
        self.screen.sb.arena_alloc = arena;
        self.saved_screen.sb.arena_alloc = arena; // alt 보관분도(현재 비었지만 일관성)
    }

    /// i=0이 가장 오래된 스크롤백 행. 범위 밖이면 null. page 저장(§11 A1)에 위임.
    pub fn scrollbackRow(self: *const TerminalCore, i: usize) ?[]const types.Cell {
        return self.screen.sb.row(i);
    }

    /// 뷰포트를 delta_up줄만큼 위(과거, 양수)/아래(현재, 음수)로 스크롤한다. [0, sb_count]로 clamp.
    /// 뷰가 바뀌면 화면 전체를 dirty로 표시한다(렌더가 새 윈도를 다시 그리도록).
    pub fn scrollViewport(self: *TerminalCore, delta_up: isize) void {
        self.owner_dbg.assertOwnedBySelf(); // reader 노출 시 core_mutex 보유 강제(디버그 전용 §6-5)
        // 지연된 재-wrap을 먼저 수행한다 — sb.count(스크롤 범위)가 재-wrap으로 바뀔 수 있다.
        // alt에서는 활성 sb.count==0이라 아래 clamp가 자연히 무동작이다(가드 불필요 — Scrollback 모델).
        screen.ensureScrollbackRewrapped(self);
        const max_off: isize = @intCast(self.screen.sb.count);
        var off: isize = @as(isize, @intCast(self.view_offset)) + delta_up;
        if (off < 0) off = 0;
        if (off > max_off) off = max_off;
        const new_off: usize = @intCast(off);
        if (new_off != self.view_offset) {
            self.view_offset = new_off;
            self.dirty = fullDirty(self.size);
        }
    }

    /// 뷰포트를 바닥(활성 화면)으로 되돌린다.
    pub fn scrollToBottom(self: *TerminalCore) void {
        self.owner_dbg.assertOwnedBySelf(); // reader 노출 시 core_mutex 보유 강제(디버그 전용 §6-5)
        if (self.view_offset != 0) {
            self.view_offset = 0;
            self.dirty = fullDirty(self.size);
        }
    }

    /// 절대 행 abs가 뷰포트 세로 중앙쯤에 오도록 스크롤한다(스크롤백 Find가 현재 매치를 화면에 보일 때).
    /// 중앙 배치라 상단 Find 오버레이에 매치가 가리지 않는다. alt screen에선 sb.count==0이라 매치가
    /// 활성 화면뿐이고 new_off가 0(바닥)으로 떨어져 자연히 무동작이다. [0, sb.count]로 clamp.
    pub fn scrollToAbs(self: *TerminalCore, abs: usize) void {
        screen.ensureScrollbackRewrapped(self); // sb.count(절대 좌표 범위)가 재-wrap으로 바뀔 수 있다
        const total = self.screen.sb.count + self.size.rows;
        if (total == 0) return;
        // 매치를 뷰포트 세로 중앙(target_top = abs - rows/2, saturating)에 둔다.
        const half = self.size.rows / 2;
        const target_top = if (abs > half) abs - half else 0;
        const new_off: usize = if (target_top < self.screen.sb.count) self.screen.sb.count - target_top else 0; // 활성 행이면 바닥
        if (new_off != self.view_offset) {
            self.view_offset = new_off;
            self.dirty = fullDirty(self.size);
        }
    }

    /// 절대 행(스크롤백 0..sb_count-1, 이어서 활성 화면)의 OSC 133 정보(분류+종료코드). 범위 밖은 기본값.
    fn promptAtAbs(self: *const TerminalCore, abs: usize) types.RowPrompt {
        if (abs < self.screen.sb.count) return self.scrollbackRowPrompt(abs);
        const active = abs - self.screen.sb.count;
        if (active < self.screen.prompt_marks.len) return self.screen.prompt_marks[active];
        return .{};
    }

    fn isPromptish(t: types.SemanticPrompt) bool {
        return t == .prompt or t == .input;
    }

    /// 닫기 확인(실행 중 명령 보호)의 **OS-중립 술어** — "커서가 셸 프롬프트에 idle하게 있는가"를 셸 통합
    /// (OSC 133 semantic prompt)과 alt 화면 상태만으로 판정한다(프로세스/pgid syscall 없음 → Linux·Windows·web에
    /// 그대로 이식된다). Ghostty `Terminal.cursorIsAtPrompt`와 같은 모델:
    ///   1. alt 화면이면(vim·claude 등 풀스크린 TUI) 프롬프트가 아니다 → 실행 중으로 본다(셸 통합 없어도 잡힘).
    ///   2. 그 외엔 semantic_state로: prompt(A~B)·input(B~C)=프롬프트, command(C~D)·unknown=프롬프트 아님.
    /// unknown(통합 없는 셸 또는 명령 종료 D 직후·RIS)은 **프롬프트 아님**으로 보수적 판정한다 — 통합이 있으면
    /// 정착한 idle 프롬프트는 항상 input이라 오확인이 없고, 통합이 없으면 안전하게 확인을 띄운다(데이터 손실
    /// 방지 우선 = Ghostty의 "통합 없으면 확인" 정책과 동일). 호출자(닫기 확인)는 `!cursorIsAtPrompt()`를 "실행 중
    /// 명령 있음"으로 쓴다. 단일 출처: docs/macos-app-host-boundary.md "닫기 확인".
    pub fn cursorIsAtPrompt(self: *const TerminalCore) bool {
        if (self.alt_active) return false;
        return isPromptish(self.semantic_state);
    }

    /// 절대 행 abs가 "프롬프트 블록의 시작"인지(점프 네비게이션·거터 타깃). 프롬프트/입력 run의 첫
    /// 행 — 직전 행이 프롬프트/입력이 아닌 곳. 명령 출력(.command)·미분류가 블록을 가른다.
    fn isPromptStart(self: *const TerminalCore, abs: usize) bool {
        if (!isPromptish(self.promptAtAbs(abs).kind)) return false;
        if (abs == 0) return true;
        return !isPromptish(self.promptAtAbs(abs - 1).kind);
    }

    /// 절대 행 abs의 종료코드를 설정한다(활성/스크롤백 통일). 거터 색 결정용.
    fn setPromptExitAtAbs(self: *TerminalCore, abs: usize, exit: i16) void {
        if (abs >= self.screen.sb.count) {
            const active = abs - self.screen.sb.count;
            if (active < self.screen.prompt_marks.len) self.screen.prompt_marks[active].exit = exit;
        } else {
            self.screen.sb.setRowPromptExit(abs, exit);
        }
    }

    /// 방금 끝난 명령(OSC 133 D)의 종료코드를 그 명령의 프롬프트 시작 행에 스탬프한다 — 커서의
    /// 절대 행에서 위로 가장 가까운 isPromptStart를 찾는다. 프롬프트가 이미 스크롤백으로 밀려났어도
    /// 거기까지 스캔해 찾는다. 못 찾으면(분류 없음) 무동작.
    /// 알려진 엣지(실 zsh에선 도달 안 함): C가 B와 같은 행에서(개행 없이) 와 입력 행이 .command로
    /// 재분류되면, 그 명령엔 promptish 시작 행이 없어 스캔이 '이전' 블록을 찍을 수 있다. 실제 zsh는
    /// Enter의 개행이 C를 새 행에 두므로 입력 행이 .input으로 남아 안전하다(합성 스트림 한정 엣지).
    // osc.zig의 OSC 133 핸들러가 호출하므로 pub(prompt 분류 storage는 core 소유, OSC 파싱은 osc.zig).
    pub fn stampPromptExit(self: *TerminalCore, exit: i16) void {
        var abs = self.screen.sb.count + self.screen.cursor.row + 1;
        while (abs > 0) {
            abs -= 1;
            if (self.isPromptStart(abs)) {
                self.setPromptExitAtAbs(abs, exit);
                return;
            }
        }
    }

    /// 이전(dir<0, 과거/위)/다음(dir>0, 최근/아래) 프롬프트 블록 시작으로 뷰포트를 스크롤한다.
    /// OSC 133 분류가 있어야 동작(셸 통합 필요). 타깃을 뷰포트 맨 위에 두고, 타깃이 활성 화면이면
    /// 바닥으로 간다. 찾으면 true. alt screen·분류 없음·해당 방향에 프롬프트 없음이면 false.
    pub fn jumpToPrompt(self: *TerminalCore, dir: i8) bool {
        if (self.alt_active) return false;
        screen.ensureScrollbackRewrapped(self); // sb_count(절대 좌표 범위)가 재-wrap으로 바뀔 수 있다
        const total = self.screen.sb.count + self.size.rows;
        if (total == 0) return false;
        const top = self.screen.sb.count - @min(self.view_offset, self.screen.sb.count); // 현재 뷰포트 맨 위 절대 행(underflow 가드)
        var target: ?usize = null;
        if (dir < 0) {
            var r = top;
            while (r > 0) {
                r -= 1;
                if (self.isPromptStart(r)) {
                    target = r;
                    break;
                }
            }
        } else {
            var r = top + 1;
            while (r < total) : (r += 1) {
                if (self.isPromptStart(r)) {
                    target = r;
                    break;
                }
            }
        }
        const t = target orelse return false;
        const new_off: usize = if (t < self.screen.sb.count) self.screen.sb.count - t else 0; // 활성 행이면 바닥
        if (new_off != self.view_offset) {
            self.view_offset = new_off;
            self.dirty = fullDirty(self.size);
        }
        return true;
    }

    /// 현재 위로 스크롤한 줄 수(0=바닥).
    pub fn viewOffset(self: *const TerminalCore) usize {
        return self.view_offset;
    }

    /// 보이는 행 r(0..rows-1)의 cells. view_offset만큼 [스크롤백 ++ 활성]을 위로 본 윈도다. 윗부분
    /// view_offset줄은 가장 최근 스크롤백, 나머지는 활성 화면 윗부분이다. 스크롤백 행이 비었으면(OOM)
    /// 빈 슬라이스를 준다. resize로 폭이 달라진 스크롤백 행은 저장된 폭 그대로 — 렌더가 clamp/pad한다.
    pub fn viewportRow(self: *const TerminalCore, r: u16) []const types.Cell {
        const ci = self.screen.sb.count - @min(self.view_offset, self.screen.sb.count) + r; // content index (underflow 가드 — 형제 호출부와 동일)
        if (ci < self.screen.sb.count) {
            return self.scrollbackRow(ci) orelse &.{};
        }
        const active_row = ci - self.screen.sb.count;
        const start = active_row * self.size.cols;
        return self.screen.cells[start .. start + self.size.cols];
    }

    /// 보이는 뷰포트에 blink(SGR 5) 셀이 하나라도 있는가. app이 blink 위상을 진행/재빌드할지 게이트로 쓴다
    /// (blink 글자가 없으면 idle 재투영을 안 한다). view_offset==0(미스크롤)이면 활성 셀만 보는 싸다.
    pub fn viewportHasBlink(self: *const TerminalCore) bool {
        var r: u16 = 0;
        while (r < self.size.rows) : (r += 1) {
            for (self.viewportRow(r)) |cell| {
                if (cell.style.blink) return true;
            }
        }
        return false;
    }

    /// 보이는 행 r의 OSC 133 정보(viewportRow와 같은 [스크롤백 ++ 활성] 윈도 인덱싱).
    pub fn viewportRowPrompt(self: *const TerminalCore, r: u16) types.RowPrompt {
        const ci = self.screen.sb.count - @min(self.view_offset, self.screen.sb.count) + r; // underflow 가드(다른 호출부와 동일)
        if (ci < self.screen.sb.count) return self.scrollbackRowPrompt(ci);
        return self.screen.prompt_marks[ci - self.screen.sb.count];
    }

    /// scroll로 위로 밀려나는 맨 윗줄을 스크롤백 ring에 보관한다. 슬롯 버퍼를 재사용해(같은 길이면
    /// memcpy만) 매 scroll에 alloc하지 않는다. OOM이면 그 행은 보관하지 않고 넘어간다(best-effort).
    /// i=0이 가장 오래된 스크롤백 행의 soft-wrap 플래그.
    pub fn scrollbackRowWrapped(self: *const TerminalCore, i: usize) bool {
        return self.screen.sb.rowWrapped(i);
    }

    /// i번째 스크롤백 행의 OSC 133 정보(i=0이 가장 오래된 행). sb_wrapped와 같은 ring 인덱싱.
    /// 없거나 범위 밖이면 기본값({.unknown, null}).
    pub fn scrollbackRowPrompt(self: *const TerminalCore, i: usize) types.RowPrompt {
        return self.screen.sb.rowPrompt(i);
    }

    /// sticky scroll 한 줄: 뷰포트 최상단 출력이 속한 명령의 **명령줄(.input) 스크롤백 행** + 종료코드.
    pub const StickyCommand = struct {
        row: usize, // 스크롤백 인덱스(0=가장 오래됨) — 이 행이 명령줄(.input). app이 scrollbackRow로 텍스트를 읽는다.
        exit: ?i16, // 그 명령의 종료코드(OSC 133 D 없으면 null=실행 중). ✓(0)/✗(≠0) 색에 쓴다.
    };

    /// 스크롤백을 위로 올렸을 때(view_offset>0) 뷰포트 최상단 출력이 속한 명령의 **명령줄(.input)** 을 찾는다 —
    /// sticky scroll 단일 출처(headless 단위 테스트 가능). 라이브 바닥(vo=0)·스크롤백 없음·명령줄이 이미 보이면
    /// null을 준다(명령줄이 뷰포트 위로 밀려났을 때만 그 행을 돌려준다). vo>0이면 최상단과 그 위는 전부 스크롤백이라
    /// (활성 화면은 항상 vo줄 아래) 스크롤백 인덱싱만 본다. 종료코드는 OSC 133 D가 프롬프트 시작 행에 스탬프하므로
    /// (osc.zig stampPromptExit) 명령줄에서 프롬프트 블록(.input/.prompt)을 위로 거슬러 첫 non-null exit를 읽는다
    /// (단일 행 프롬프트면 명령줄 자체가 exit를 든다). 명령이 실행 중(D 없음)이면 exit=null이라 ✓/✗ 없이 명령줄만.
    pub fn stickyCommand(self: *const TerminalCore) ?StickyCommand {
        const vo = self.view_offset;
        if (vo == 0) return null; // 라이브 바닥 — sticky 없음
        const count = self.screen.sb.count;
        if (count == 0 or vo > count) return null;
        const top = count - vo; // 뷰포트 최상단의 스크롤백 인덱스(이 위는 전부 스크롤백)
        const top_kind = self.scrollbackRowPrompt(top).kind;
        if (top_kind == .input or top_kind == .prompt) return null; // 명령줄/프롬프트가 이미 최상단에 보임 — 불필요
        // 최상단이 출력(.command)/미분류(.unknown) — 위로 거슬러 가장 가까운 명령줄(.input)을 찾는다.
        var cmd_row: ?usize = null;
        var i = top;
        while (i > 0) {
            i -= 1;
            if (self.scrollbackRowPrompt(i).kind == .input) {
                cmd_row = i;
                break;
            }
        }
        const cr = cmd_row orelse return null; // 위에 명령줄 없음(통합 안 됨/맨 위) — sticky 없음
        var exit: ?i16 = null;
        var j = cr;
        while (true) {
            const rp = self.scrollbackRowPrompt(j);
            if (rp.kind != .input and rp.kind != .prompt) break; // 프롬프트 블록을 벗어남
            if (rp.exit) |e| {
                exit = e;
                break;
            }
            if (j == 0) break;
            j -= 1;
        }
        return .{ .row = cr, .exit = exit };
    }

    /// 붙여넣기 바이트를 PTY 입력으로 인코딩한다(bracketed paste 래핑 + CR 정규화 + 위험 제어 바이트 방어).
    /// 본문: input_report.encodePaste. 호출자가 free한다.
    pub fn encodePaste(self: *const TerminalCore, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        return input_report.encodePaste(self, allocator, bytes);
    }

    /// bracketed paste(DECSET 2004)가 켜졌는가 — 인코딩에 필요한 **유일한** 코어 상태다. app이 core_mutex 아래에서
    /// 이 bool만 읽고, 실제 인코딩(할당 + payload 복사)은 락 밖에서 `input_report.encodePasteWith`로 한다
    /// (멀티MB 붙여넣기를 락 안에서 인코딩하면 그 pane의 PTY reader가 그동안 막힌다 — code-review).
    pub fn bracketedPasteEnabled(self: *const TerminalCore) bool {
        return self.bracketed_paste;
    }

    /// 이 붙여넣기가 paste protection 확인을 요구하는지(개행/ESC[201~ 인젝션 + bracketed 상태·설정 반영).
    /// 본문: input_report.pasteNeedsConfirmation. app이 확인 모달을 띄울지 결정하는 데 쓴다.
    pub fn pasteNeedsConfirmation(self: *const TerminalCore, data: []const u8, protection_enabled: bool, bracketed_safe: bool) bool {
        return input_report.pasteNeedsConfirmation(self, data, protection_enabled, bracketed_safe);
    }

    // ── 선택/검색/URL facade — 본문은 selection.zig(외부 점-호출이라 struct 메서드로 잔류) ──────────
    /// 선택 시작(마우스 다운). 본문: selection.selectionStart.
    pub fn selectionStart(self: *TerminalCore, viewport_row: u16, col: u16) void {
        selection.selectionStart(self, viewport_row, col);
    }
    /// 블록(직사각형) 선택 모드 토글. 본문: selection.setSelectionBlock.
    pub fn setSelectionBlock(self: *TerminalCore, on: bool) void {
        selection.setSelectionBlock(self, on);
    }
    /// 선택 확장(드래그). 본문: selection.selectionExtend.
    pub fn selectionExtend(self: *TerminalCore, viewport_row: u16, col: u16) void {
        selection.selectionExtend(self, viewport_row, col);
    }
    /// 더블클릭 단어 선택. 본문: selection.selectWordAt.
    pub fn selectWordAt(self: *TerminalCore, viewport_row: u16, col: u16, separator_bytes: []const u8) void {
        selection.selectWordAt(self, viewport_row, col, separator_bytes);
    }

    /// Cmd+hover/클릭 링크 anchor 절대 좌표. 본문: selection.urlAnchorAt. scopes=감지 범위(config).
    pub fn urlAnchorAt(self: *const TerminalCore, viewport_row: u16, col: u16, scopes: selection.LinkScopes) ?types.SelectionPoint {
        return selection.urlAnchorAt(self, viewport_row, col, scopes);
    }
    /// hover 밑줄용 anchor — **클릭과 같은 검증을 거친다.**
    ///
    /// `urlAnchorAt`은 분류만 한다. 그래서 지금까지 hover는 "패턴이 맞으면 밑줄"이었고 클릭만 존재검증을 했다 —
    /// 존재하지 않는 경로에 밑줄이 뜨고 클릭하면 아무 일도 안 일어나는 상태가 **OS를 가리지 않고** 생겼다
    /// (`/nonexistent/x`도, 이스케이프 출력이 경로처럼 보이는 것도). 그 불일치는 `linkScopesForTerm`의 doc이
    /// 이미 *"밑줄 보이는 곳 = 열리는 곳"*을 불변식으로 선언해 둔 것과 어긋난다.
    ///
    /// **URL은 stat하지 않는다** — 열 수 있는지는 네트워크가 정하고, 그걸 hover에서 물으면 안 된다.
    /// 파일 경로만 `extractUrlAt`과 **같은 resolve+존재검증**을 거친다(단일 출처가 하나여야 둘이 안 갈린다).
    ///
    /// **비용**(실측, Windows 10.0.19045, 이 함수 **호출 전체**를 400회 평균). 처음에는 stat 한 겹만 재서 숫자를
    /// 6배 낮게 적었다 — 적대적 검증에서 잡아 다시 쟀다:
    ///
    /// | hover 1회 | 변경 전(`urlAnchorAt`) | 지금 | 120Hz 이동 간격(8333 µs) 대비 |
    /// |---|---|---|---|
    /// | 링크 아님 — 대부분의 마우스 이동 | 2.0 µs | 2.0 µs | 0.02 % |
    /// | URL | 3.8 µs | 38.0 µs | 0.46 % |
    /// | 실재 경로 | 11.6 µs | 114.7 µs | 1.38 % |
    /// | 없는 경로 | 14.0 µs | 118.1 µs | 1.42 % |
    ///
    /// stat 자체는 그중 3 %뿐이고(`GetFileAttributesW` 3.5 µs) 나머지는 토큰 수집과 `std.fs.path.resolve`다.
    /// 즉 비용은 "디스크를 만져서"가 아니라 "분류만 하던 것을 추출까지 해서" 는다. 완화가 둘 있다 — 링크가 아닌
    /// 단어에서는 **할당도 비용도 0**이고(위 표 첫 줄), 호출부가 **수식키를 누른 동안에만** 부른다.
    ///
    /// **네트워크 경로만 위험한데**(응답 없는 UNC 호스트 755 ms, 라우팅 불가 IP 11 s) UNC는
    /// `isDetectableAbsoluteFor`가 감지 단계에서 이미 거부하므로 여기까지 오지 않는다. 남은 미지수는 **매핑된 채
    /// 끊긴 네트워크 드라이브**이고, 그건 이 기기에 없어 재지 못했다.
    ///
    /// **캐시를 두지 않았다.** 같은 anchor 위에서 마우스가 흔들리면 매번 다시 계산하고, 실측상 그 반복의 89 %가
    /// 1-entry 캐시로 사라진다. 절대값이 이동 간격의 1.4 %라 지금은 복잡도를 사지 않는다(docs/windows-platform.md
    /// §5.1a "두지 않은 완화").
    pub fn openableLinkAnchorAt(
        self: *const TerminalCore,
        allocator: std.mem.Allocator,
        viewport_row: u16,
        col: u16,
        scopes: selection.LinkScopes,
    ) !?HoverLink {
        const anchor = selection.urlAnchorAt(self, viewport_row, col, scopes) orelse return null;
        const link = (try self.openableLinkAt(allocator, viewport_row, col, scopes)) orelse return null;
        allocator.free(link.text);
        // 공백 든 경로는 토큰보다 넓다 — 밑줄이 그 끝까지 가야 "밑줄 보이는 곳 = 열리는 곳"이 성립한다.
        return .{ .anchor = anchor, .end = if (link.bounds) |b| b.end else null };
    }

    /// anchor에서 시작하는 링크의 현재 뷰포트 밑줄 범위(종류 무관). 본문: selection.urlSpanAtAbs.
    pub fn urlSpanAtAbs(self: *const TerminalCore, anchor: types.SelectionPoint) ?types.SelectionSpan {
        return selection.urlSpanAtAbs(self, anchor);
    }
    /// 절대 좌표 두 점 사이의 밑줄 범위(뷰포트 클립). 본문: selection.spanBetweenAbs.
    /// hover가 공백 확장으로 정해 둔 범위를 매 프레임 그릴 때 쓴다(재계산하지 않는다).
    pub fn spanBetweenAbs(self: *const TerminalCore, start: types.SelectionPoint, end: types.SelectionPoint) ?types.SelectionSpan {
        return selection.spanBetweenAbs(self, start, end);
    }
    /// 현재 뷰포트에 보이는 링크 전체(자동 감지 + OSC 8). 본문: selection.collectViewportLinks. 원격(host-backed)
    /// 세션에서 host가 client에 실어 보낼 목록을 만드는 데 쓴다(docs/link-detection.md §원격(host-backed) 세션).
    pub fn collectViewportLinks(self: *const TerminalCore, allocator: std.mem.Allocator, scopes: selection.LinkScopes, out: *std.ArrayList(selection.ViewportLink)) !void {
        return selection.collectViewportLinks(self, allocator, scopes, out);
    }
    /// Cmd+클릭 위치의 링크 추출 + file_path면 cwd/$HOME resolve·존재검증(호출자가 .text를 free). url(스킴·OSC 8)은
    /// 그대로, file_path는 존재하는 절대 경로(없으면 전체 null=일반 클릭). 분류는 selection, resolve는 resolveClickedPath.
    pub fn extractUrlAt(self: *const TerminalCore, allocator: std.mem.Allocator, viewport_row: u16, col: u16, scopes: selection.LinkScopes) !?selection.ExtractedLink {
        const r = (try self.openableLinkAt(allocator, viewport_row, col, scopes)) orelse return null;
        return .{ .text = r.text, .kind = r.kind };
    }

    /// 열 수 있는 링크 하나 — 텍스트(호출자 소유)와 **화면 범위**를 함께 준다. 밑줄은 그 범위를 그린다.
    ///
    /// **공백 든 경로를 여기서 잡는다.** 토큰 모델은 공백을 경계로 보므로 `C:\Program Files\x.txt`가
    /// `C:\Program`에서 잘리고, 잘린 것은 존재 게이트가 죽인다 — 즉 예전에는 공백 경로가 **전혀** 안 잡혔다
    /// (실측). 규칙은 `bare_relative`를 열 때와 같은 것이다: **문법으로 못 가르니 존재로 가른다.** 토큰이
    /// 그대로 실재하면 그것을 쓰고, 아니면 공백 세그먼트를 하나씩 붙여 다시 물어 **실재하는 가장 긴 것**을
    /// 취한다. 산문은 저절로 멈춘다(`/tmp/a and then` 같은 경로가 없으므로).
    ///
    /// **상한이 있다**(`max_space_segments`). 없으면 화면 끝까지 stat을 반복한다. 실측(Windows,
    /// `GetFileAttributesW` + UTF-16 변환 포함): 확장 1회당 ~40 µs이고 상한 5면 최악 ~200 µs — 120Hz 마우스
    /// 이동 간격 8333 µs의 2.4 %다. **공백이 없는 흔한 경로는 확장을 아예 안 탄다**(첫 물음에서 실재하므로).
    ///
    /// URL은 확장하지 않는다 — 공백은 URL의 종결자이지 일부가 아니다.
    pub fn openableLinkAt(
        self: *const TerminalCore,
        allocator: std.mem.Allocator,
        viewport_row: u16,
        col: u16,
        scopes: selection.LinkScopes,
    ) !?OpenableLink {
        const ext = (try selection.extractUrlAt(self, allocator, viewport_row, col, scopes)) orelse return null;
        // **OSC 8 명시 링크는 bounds를 주지 않는다.** 그 링크의 보이는 텍스트는 공백을 품을 수 있고
        // (`ESC]8;;uri ST My File ESC]8;; ST`), 그 범위는 셀의 link id가 정한다(`linkBoundsAt`) — 토큰
        // 경계를 끝으로 실으면 밑줄이 첫 단어로 **줄어든다.** null을 주면 밑줄이 예전 경로(`urlSpanAtAbs`)를
        // 쓰고, 그쪽이 link id를 먼저 본다.
        if (selection.cellHasOsc8Link(self, viewport_row, col))
            return .{ .text = ext.text, .kind = ext.kind, .bounds = null };
        const base_bounds = selection.wordBoundsAtPublic(self, viewport_row, col);
        if (ext.kind == .url) return .{ .text = ext.text, .kind = .url, .bounds = base_bounds };
        defer allocator.free(ext.text);

        // 토큰에서 시작해 공백 세그먼트를 붙여 가며 **실재하는 가장 긴 것**을 찾는다.
        //
        // **토큰이 실재해도 멈추지 않는 이유**(적대적 검증에서 잡았다): 화면이 `.../Documents Backup`인데
        // 토큰 `.../Documents`가 실재하면, 거기서 끊으면 **사용자가 보고 있는 것과 다른 것**을 연다. 그래서
        // 실재하더라도 한 칸 더 물어본다. 대신 **연속 실패 2회**면 멈춘다 — 그것이 비용 상한이다.
        var bounds = base_bounds orelse return null;
        var best: ?OpenableLink = null;
        errdefer if (best) |b| allocator.free(b.text);
        if (self.resolveClickedPath(allocator, ext.text) catch null) |abs|
            best = .{ .text = abs, .kind = .file_path, .bounds = bounds };

        var seg: usize = 0;
        var misses: usize = 0;
        while (seg < max_space_segments and misses < max_consecutive_misses) : (seg += 1) {
            const next_end = selection.extendEndOneSegment(self, bounds.end) orelse break;
            bounds = .{ .start = bounds.start, .end = next_end };
            const wider = (try selection.extractFromBounds(self, allocator, bounds, scopes)) orelse {
                misses += 1;
                continue;
            };
            defer allocator.free(wider.text);
            if (wider.kind != .file_path) {
                misses += 1;
                continue;
            }
            const abs = (self.resolveClickedPath(allocator, wider.text) catch null) orelse {
                misses += 1;
                continue;
            };
            misses = 0;
            if (best) |b| allocator.free(b.text);
            best = .{ .text = abs, .kind = .file_path, .bounds = bounds };
        }
        return best;
    }

    /// file_path 링크 raw 텍스트(`:line:col` 포함 가능)를 절대 경로로 resolve하고, 존재하면 그 경로(호출자 소유)를,
    /// 아니면 null을 돌려준다. `:line[:col]` 분리 → `~/`를 $HOME 확장 → 상대면 currentCwd()(OSC 7)와 join →
    /// 정규화 → `pathExists` 존재 검증(OS별 API — 그 함수 doc). cwd가 비면 상대 경로는 resolve 불가(null). 단일 출처: docs/link-detection.md.
    /// 파일 I/O는 코어 책임(순수 분류 레이어 selection.zig엔 stat을 두지 않는다). cwd(currentCwd)와 스크롤백을 읽으므로
    /// 호출자(app_session.urlAt)가 lockCore 아래에서 부른다 — reader 스레드가 OSC 7로 cwd를 free+realloc하는 race를
    /// 막는다(focusedTermCwd 선례). 존재검증은 빠른 syscall이라 락 아래 허용(docs/plans/io-render-threading.md §9.1).
    fn resolveClickedPath(self: *const TerminalCore, allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
        // 끝의 ":<digits>(:<digits>)?"(에디터 줄/열 점프 관례)를 떼고 순수 경로만 — 1차는 파일만 연다(줄 점프는 후속).
        var path_end = raw.len;
        var rounds: usize = 0;
        while (rounds < 2) : (rounds += 1) {
            var j = path_end;
            while (j > 0 and std.ascii.isDigit(raw[j - 1])) j -= 1;
            if (j < path_end and j > 0 and raw[j - 1] == ':') path_end = j - 1 else break;
        }
        const path_part = raw[0..path_end];
        if (path_part.len == 0) return null;

        // ~/ → $HOME/... ($HOME은 정적 getenv(libc) — 터미널 코어는 std.Io 인터페이스를 안 든다. 없으면 null).
        var tilde_buf: ?[]u8 = null;
        defer if (tilde_buf) |t| allocator.free(t);
        var rel_or_abs: []const u8 = path_part;
        if (std.mem.startsWith(u8, path_part, "~/")) {
            const home_z = std.c.getenv("HOME") orelse return null;
            const home = std.mem.span(home_z);
            // getenv는 빈 HOME("")에도 non-null을 주므로 절대 경로가 아니면 거른다 — 안 그러면 "~/foo"가 상대
            // 경로 "foo"가 돼 cwd 기준으로 엉뚱하게 resolve된다(resolveWorkspaceRoot의 isAbsolute 가드와 같은 이유).
            if (!std.fs.path.isAbsolute(home)) return null;
            tilde_buf = try std.fs.path.join(allocator, &.{ home, path_part[2..] });
            rel_or_abs = tilde_buf.?;
        }

        // 절대 경로로 정규화(상대면 OSC 7 cwd 기준 — cwd를 모르면 resolve 불가). resolve가 ../ ./ 중복/ 를 정리.
        const abs = blk: {
            if (std.fs.path.isAbsolute(rel_or_abs)) break :blk try std.fs.path.resolve(allocator, &.{rel_or_abs});
            const cwd = self.currentCwd();
            if (cwd.len == 0) return null;
            break :blk try std.fs.path.resolve(allocator, &.{ cwd, rel_or_abs });
        };
        errdefer allocator.free(abs);

        // 존재 검증 — 없으면 무시(오탐·미존재 경로 차단). 디렉토리도 허용(NSWorkspace가 Finder로 연다).
        if (!try pathExists(allocator, abs)) {
            allocator.free(abs);
            return null;
        }
        return abs;
    }

    /// 경로가 실재하는가. **OS마다 다른 API를 쓴다** — 같은 syscall의 이름 차이가 아니라 인코딩 계약이 다르다.
    ///
    /// POSIX는 `std.c.access(F_OK)`다(std.Io 우회 — 코어는 io 인터페이스를 안 든다; `pty/macos.zig` 선례).
    /// 바이트 경로가 곧 커널이 보는 경로라 UTF-8이 그대로 통한다.
    ///
    /// **Windows는 `GetFileAttributesW`(UTF-16)를 쓴다.** CRT의 `_access`는 바이트 문자열을 UTF-8이 아니라
    /// **ANSI 코드페이지**로 읽기 때문이다. 실측(이 기계 ACP=949): `한글`·`日本`·`café`·이모지 이름의 디렉터리를
    /// 만들어 놓고 물으면 Win32(UTF-16)는 전부 `true`인데 CRT는 전부 `false`를 냈다. 그래서 비-ASCII 이름이 든
    /// 경로는 **클릭해도 안 열리고 밑줄도 안 떴다**. ASCII 대조군은 두 API가 같은 답을 낸다.
    /// 비용은 같은 자릿수다(실측 3.5 µs 대 3.6 µs) — 정확도를 위해 속도를 내주는 거래가 아니다.
    fn pathExists(allocator: std.mem.Allocator, abs: []const u8) !bool {
        if (builtin.os.tag == .windows) {
            // 손상 UTF-8은 경로가 될 수 없다 — "없음"으로 접는다(할당 실패와 구분해 올린다).
            const w = std.unicode.utf8ToUtf16LeAllocZ(allocator, abs) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            defer allocator.free(w);
            return GetFileAttributesW(w.ptr) != invalid_file_attributes;
        }
        const abs_z = try allocator.dupeZ(u8, abs);
        defer allocator.free(abs_z);
        return std.c.access(abs_z.ptr, std.posix.F_OK) == 0;
    }

    /// 트리플클릭 줄 선택. 본문: selection.selectLineAt.
    pub fn selectLineAt(self: *TerminalCore, viewport_row: u16) void {
        selection.selectLineAt(self, viewport_row);
    }
    /// 전체 내용(스크롤백 + 화면) 선택(⌘A). 본문: selection.selectAll.
    pub fn selectAll(self: *TerminalCore) void {
        selection.selectAll(self);
    }

    /// 화면 + 스크롤백을 비운다(⌘K). 베이스/결정: Ghostty `clear_screen`(키바인딩 수렴의 1차 레퍼런스 —
    /// docs/key-input-and-shortcuts.md). 반환값 = 호출자가 셸에 form-feed(0x0C, ^L)를 보내 프롬프트를 맨 위에
    /// 다시 그리게 할지 여부. 코어는 PTY로 못 쓰므로(L1 경계 — docs/io-render-threading.md) "보낼지"만 알려주고
    /// 실제 쓰기는 app_session이 락 밖에서 한다.
    ///
    /// 세 경로(전부 Ghostty와 동작 일치):
    /// 1. alt 화면(vim/less/htop): 무동작(false). 그 화면은 앱이 소유하고 셀을 에뮬레이터가 지우면 앱의 커서
    ///    모델과 어긋난다. clear는 앱 자신(:clear 등)에 맡긴다.
    /// 2. 셸 프롬프트(OSC 133 prompt/input): 화면 전체 + 스크롤백을 비우고 커서를 홈으로 둔 뒤 true 반환 →
    ///    셸이 ^L(clear-screen 위젯)로 프롬프트를 맨 위에 다시 그린다. 셸이 커서를 다시 잡으므로 readline 모델과
    ///    어긋나지 않는다(프롬프트 분류는 셸 통합이 있을 때만 = 그때 ^L이 정상 동작).
    /// 3. 그 외(셸 통합 없음/명령 실행 중): 스크롤백 + 커서 위 행만 비우고 현재 줄과 그 아래·커서는 보존, false.
    ///    커서를 안 옮겨 비통합 셸·실행 중 프로그램의 커서 모델과 어긋나지 않게 하고 form-feed도 안 보낸다.
    pub fn clearScreen(self: *TerminalCore) bool {
        if (self.alt_active) return false;
        if (self.size.rows == 0 or self.size.cols == 0) return false;
        self.screen.pending_wrap = false;
        screen.clearScrollback(self); // 스크롤백(history)은 항상 비운다 — 프롬프트 위치와 무관, selection도 무효화
        const blank: types.Cell = .{ .style = self.screen.pen };

        if (isPromptish(self.semantic_state)) {
            @memset(self.screen.cells, blank);
            @memset(self.screen.wrapped, false);
            @memset(self.screen.prompt_marks, .{}); // 전체 clear는 OSC 133 분류도 지운다(셸이 곧 재마킹)
            self.semantic_state = .unknown;
            self.screen.cursor = .{ .row = 0, .col = 0 };
            self.screen.last_print = null;
            self.dirty = fullDirty(self.size);
            return true;
        }

        // 비프롬프트: 커서 행 위쪽만 비운다. index(row,0) = 커서 행 시작 셀 인덱스 = 위쪽 행들의 셀 수.
        if (self.screen.cursor.row > 0) {
            const above = self.index(self.screen.cursor.row, 0);
            @memset(self.screen.cells[0..above], blank);
            for (0..self.screen.cursor.row) |r| {
                self.screen.wrapped[r] = false;
                self.screen.prompt_marks[r] = .{};
            }
            self.screen.last_print = null;
            self.dirty = fullDirty(self.size);
        }
        return false;
    }

    /// 스크롤백 + 화면에서 needle 검색(Find, out에 절대 좌표 매치). 본문: selection.findMatches.
    pub fn findMatches(self: *TerminalCore, allocator: std.mem.Allocator, needle_utf8: []const u8, out: *std.ArrayList(types.Match)) !void {
        return selection.findMatches(self, allocator, needle_utf8, out);
    }
    /// 검색 매치를 뷰포트 좌표로 클립. 본문: selection.matchViewportSpan.
    pub fn matchViewportSpan(self: *const TerminalCore, m: types.Match) ?types.SelectionSpan {
        return selection.matchViewportSpan(self, m);
    }
    /// 선택 해제. 본문: selection.selectionClear. screen.clearScrollback·invalidateSelection seam이 self로 호출.
    pub fn selectionClear(self: *TerminalCore) void {
        selection.selectionClear(self);
    }

    /// 행을 재배치하는 연산이 선택의 절대-행 좌표 불변식을 깨면 선택을 해제하는 단일 chokepoint.
    /// 절대 좌표가 내용을 자연히 따라가는 경우는 전체 화면 LF 스크롤(밀려난 줄이 스크롤백으로 가고
    /// eviction은 shiftSelectionForEviction가 보정)뿐이고, 그 외 모든 재배치(부분 region 스크롤,
    /// IL/DL/RI, alt 전환, resize reflow, ED3 clear)는 좌표가 어긋나므로 해제한다. selectionClear의
    /// 별칭이지만, 호출부가 "왜 해제하나"(불변식 보호)를 드러내게 별도 이름을 둔다.
    /// screen.clearScrollback(scrollback storage)이 cross-file 호출 — pub.
    pub fn invalidateSelection(self: *TerminalCore) void {
        self.selectionClear();
    }

    /// 가장 오래된 n개 행이 빠질 때 활성 화면의 abs-좌표 상태(선택·placement anchor)를 한꺼번에
    /// 보정한다. 스크롤백 eviction 규율의 단일 출처 — pushScrollback의 ring-full eviction(n=1)과
    /// setMaxScrollback의 하향 트림(n=drop)이 둘 다 이걸 통해 보정해, 보정 로직이 한 곳에만 산다.
    /// view_offset 클램프/dirty는 count가 줄어드는 트림 경로에만 필요해 호출자가 따로 처리한다
    /// (eviction은 ring-full이라 count 불변 → 불필요).
    /// screen.pushScrollback(eviction)이 cross-file 호출 — pub.
    pub fn shiftCoordsForEviction(self: *TerminalCore, n: usize) void {
        selection.shiftSelectionForEviction(self, n);
        kitty.shiftPlacementsForEviction(self, n);
    }

    /// 현재 뷰포트에 보이는 선택 범위(렌더용). 본문: selection.selectionViewportSpan.
    pub fn selectionViewportSpan(self: *const TerminalCore) ?types.SelectionSpan {
        return selection.selectionViewportSpan(self);
    }
    /// 선택 텍스트 추출(클립보드 복사, 호출자가 free). 본문: selection.extractSelection.
    pub fn extractSelection(self: *const TerminalCore, allocator: std.mem.Allocator) !?[]u8 {
        return selection.extractSelection(self, allocator);
    }

    /// PTY 출력 바이트를 VT 상태기계로 처리한다. 본문(escape/CSI/OSC/DCS/APC + UTF-8 디코드)은
    /// parser.feed가 소유 — 외부(session/app)가 점-호출하므로 facade 메서드로 남긴다(Zig dot-call 계약).
    /// owner_dbg 확인은 public 진입 계약이라 여기 둔다(reader 노출 시 core_mutex 보유 강제 §6-5).
    pub fn write(self: *TerminalCore, bytes: []const u8) !void {
        self.owner_dbg.assertOwnedBySelf();
        if (bytes.len > 0) _ = self.observer_generation.fetchAdd(1, .release);
        return parser.feed(self, bytes);
    }

    pub fn observerGeneration(self: *const TerminalCore) u64 {
        return self.observer_generation.load(.acquire);
    }

    /// OSC 10/11로 설정된 전경/배경 색 override(없으면 null = theme 기본). app이 렌더러 default 색과 화면
    /// clear color를 `override orelse theme`로 정할 때 쓴다(OSC 4 paletteOverride와 같은 결).
    pub fn defaultFgOverride(self: *const TerminalCore) ?types.Rgb {
        return self.default_fg_override;
    }
    pub fn defaultBgOverride(self: *const TerminalCore) ?types.Rgb {
        return self.default_bg_override;
    }

    /// 렌더러가 `.indexed` 색을 풀 때 참조하는 OSC 4 팔레트 override 표(null = 기본 xterm256). app이
    /// CellColors.palette로 wiring한다 — 코어는 셀 픽셀을 모르고 표만 들고 있다(K1 경계).
    pub fn paletteOverride(self: *const TerminalCore) *const [256]?types.Rgb {
        return &self.palette_override;
    }

    /// config theme.palette(ANSI 16색 base)를 주입한다 — OSC 4가 없을 때의 base 레이어. platform이 createTerm에서
    /// appearance.theme.palette로 주입하며, OSC 4 query 응답이 렌더(metal_frame)와 같은 우선순위(override > config >
    /// xterm256)를 보도록 한다. RIS/OSC104는 override만 리셋하고 이 base는 건드리지 않는다(렌더 동작과 일치).
    pub fn setConfigPalette(self: *TerminalCore, palette: [16]?types.Rgb) void {
        self.config_palette = palette;
    }

    /// DECSCNM(G9) 화면 반전 상태. app이 CellColors.screen_reverse·clear color에 반영한다(코어는 셀 색을 안 바꾼다).
    pub fn reverseScreen(self: *const TerminalCore) bool {
        return self.reverse_screen;
    }

    /// OSC 52로 들어온 clipboard 쓰기 요청(디코드된 바이트). 없으면 빈 슬라이스. platform이 정책(allow)을 확인한
    /// 뒤 system clipboard에 쓰고 clearClipboardWrite한다 — 코어는 OS clipboard를 직접 만지지 않는다(경계).
    pub fn pendingClipboardWrite(self: *const TerminalCore) []const u8 {
        return self.clipboard_write.items;
    }

    /// clearClipboardWrite가 대용량 drain 후 capacity를 반납할지 판단하는 임계치(osc_retain_bytes와 같은 취지).
    const clipboard_write_retain_bytes: usize = 4096;

    pub fn clearClipboardWrite(self: *TerminalCore) void {
        // 한 문단 이상(최대 max_clipboard_bytes=16MB) 디코드 버퍼는 drain 후 capacity를 반납한다 —
        // clearRetainingCapacity만 하면 16MB가 세션 내내 상주한다(osc_buffer 반납과 대칭; 옛 2048 OSC 버퍼
        // 시절엔 clipboard_write가 ~1.5KB를 못 넘어 무해했으나, 대용량 OSC 52를 받는 지금은 반납이 필요).
        if (self.clipboard_write.capacity > clipboard_write_retain_bytes)
            self.clipboard_write.clearAndFree(self.allocator)
        else
            self.clipboard_write.clearRetainingCapacity();
    }

    /// OSC 52 클립보드 쓰기가 상한 초과로 거부됐는지 1회성으로 가져온다(drain하면 false). platform이 매 tick
    /// 호출해 true면 사용자에게 notice로 알린다 — 무음 실패 대신 "왜 복사가 안 됐는지"를 보여준다. take_bell과 같은 결.
    pub fn takeClipboardWriteRejected(self: *TerminalCore) bool {
        const rejected = self.clipboard_write_rejected;
        self.clipboard_write_rejected = false;
        return rejected;
    }

    /// OSC 52 읽기(`?` 쿼리)가 대기 중인지. platform이 매 tick 확인해 osc52.read 정책 통과 시 클립보드를 읽어 응답한다.
    pub fn clipboardReadPending(self: *const TerminalCore) bool {
        return self.clipboard_read_pending;
    }

    /// 그 읽기 쿼리의 target(Pc) 문자열(응답 OSC 52에 그대로 echo). pending이 아니면 빈 슬라이스.
    pub fn clipboardReadTarget(self: *const TerminalCore) []const u8 {
        return self.clipboard_read_target.items;
    }

    /// 읽기 pending을 소비(비움). platform이 정책 확인·응답(또는 거부) 후 호출한다 — 다음 tick에 또 트리거되지 않게.
    pub fn clearClipboardRead(self: *TerminalCore) void {
        self.clipboard_read_pending = false;
        self.clipboard_read_target.clearRetainingCapacity();
    }

    /// OSC 9/777로 들어온 데스크톱 알림(title, body). 없으면 null. platform이 매 tick drain해 네이티브 알림으로
    /// 띄우고 clearNotification한다 — 코어는 OS 알림을 직접 만지지 않는다(경계, OSC 52와 같은 결).
    pub fn pendingNotification(self: *const TerminalCore) ?struct {
        title: []const u8,
        body: []const u8,
        generation: u64,
    } {
        if (!self.notification_pending) return null;
        return .{
            .title = self.notification_title.items,
            .body = self.notification_body.items,
            .generation = self.notification_generation,
        };
    }

    pub fn clearNotification(self: *TerminalCore) void {
        self.notification_pending = false;
        self.notification_title.clearRetainingCapacity();
        self.notification_body.clearRetainingCapacity();
    }

    pub fn clearNotificationIfGeneration(
        self: *TerminalCore,
        expected_generation: u64,
    ) bool {
        if (!self.notification_pending or
            self.notification_generation != expected_generation) return false;
        self.clearNotification();
        return true;
    }

    /// OSC 9/777 notification이 parser 상한에서 폐기됐는지 exact once 가져온다.
    pub fn takeNotificationWriteRejected(self: *TerminalCore) bool {
        const rejected = self.notification_write_rejected;
        self.notification_write_rejected = false;
        return rejected;
    }

    /// 마지막 ConEmu OSC 9;4 progress payload(`4;state[;value]`). 없으면 빈 슬라이스다.
    pub fn agentProgress(self: *const TerminalCore) []const u8 {
        return self.agent_progress.items;
    }

    /// observer가 최신 progress event를 복사한 뒤 소비한다. 상태 자체는 observer가 안정화해 보존하므로, 완료 시점의
    /// `4;0`이 다음 작업의 PTY activity를 영구히 idle로 덮는 stale metadata가 되지 않는다.
    pub fn clearAgentProgress(self: *TerminalCore) void {
        self.agent_progress.clearRetainingCapacity();
    }

    /// G12 BEL: pending 벨이 있으면 true를 돌려주고 플래그를 비운다(한 번 울리고 소비). platform이 매 tick
    /// 호출해 시스템 벨(NSSound.beep)을 울린다 — 코어는 OS 소리를 직접 내지 않는다(OSC 52/9·777과 같은 경계).
    /// BEL이 대기 중인가 — **소비하지 않는다**. host가 "즉시 관측이 필요한지" 판정하는 데 쓴다(takeBell은
    /// 관측을 만들 때 한 번만 호출해야 하므로 조회용을 따로 둔다).
    pub fn bellPending(self: *const TerminalCore) bool {
        return self.bell_pending;
    }

    pub fn takeBell(self: *TerminalCore) bool {
        const had = self.bell_pending;
        self.bell_pending = false;
        return had;
    }

    /// 셀 픽셀 크기를 platform이 주입한다(폰트·DPI·resize 시 갱신). kitty 자동 크기 이미지의 커서 advance에
    /// 쓴다(마우스 1016이 픽셀을 주입하는 것과 같은 결). 그 외 픽셀↔셀 환산은 렌더러 책임(K1).
    pub fn setCellMetrics(self: *TerminalCore, cell_width_px: u32, cell_height_px: u32) void {
        self.cell_width_px = cell_width_px;
        self.cell_height_px = cell_height_px;
    }

    /// 기본 전경/배경 색(theme RGB)을 platform이 주입한다(셀 메트릭과 같은 결). OSC 10/11 색 질의 응답에
    /// 쓴다 — 코어는 Color.default 추상만 알아 실제 theme RGB를 받아야 질의에 답할 수 있다.
    pub fn setDefaultColors(self: *TerminalCore, fg: types.Rgb, bg: types.Rgb) void {
        self.default_fg_rgb = fg;
        self.default_bg_rgb = bg;
    }

    /// 렌더 placement view 합성. 본문: kitty.buildPlacementViews. screen.snapshot이 self.로 호출(screen→kitty 역전 방지 facade).
    pub fn buildPlacementViews(self: *TerminalCore, top_abs: usize) []const types.KittyPlacement {
        return kitty.buildPlacementViews(self, top_abs);
    }
    /// 렌더 image view 합성. 본문: kitty.buildImageViews. screen.renderSnapshot이 self.로 호출(facade).
    pub fn buildImageViews(self: *TerminalCore) []const types.KittyImageView {
        return kitty.buildImageViews(self);
    }

    /// OSC 7로 셸이 보고한 현재 cwd(percent-decode된 경로). 한 번도 안 받았으면 빈 슬라이스.
    /// 창 제목 등 platform layer가 읽는다(facade를 통해 노출).
    pub fn currentCwd(self: *const TerminalCore) []const u8 {
        return self.cwd orelse "";
    }

    /// 그 cwd를 보고한 호스트(OSC 7 authority). 빈 authority(`file:///path` = VTE 규약 localhost)이거나
    /// 한 번도 안 받았으면 빈 슬라이스다. **이 값만으로 원격이라 단정하지 않는다** — 사용자 rc나 다른
    /// 터미널의 통합은 로컬 셸에서도 자기 hostname을 실어 보내므로, 로컬 여부는 `hostIsLocal`이 로컬
    /// hostname과 대조해 정한다(docs/ssh-integration.md §9.2).
    ///
    /// maru 자신의 **로컬** 셸 통합은 authority를 비워 보낸다(shell_integration.zig) — 로컬 pty 전용
    /// 스크립트라 보고하는 cwd가 정의상 로컬이고, hostname 두 스냅샷의 어긋남으로 자기 세션을 원격으로
    /// 오판하는 경로를 아예 없애기 위해서다. 원격 rc의 스니펫은 계속 `${HOST}`를 싣는다(§9.5).
    pub fn currentCwdHost(self: *const TerminalCore) []const u8 {
        return self.cwd_host orelse "";
    }

    /// OSC 7 authority가 **로컬**을 가리키는지. 순수 판정이라 I/O가 없고(호출자가 로컬 hostname을 넘긴다)
    /// OS-중립이다. 로컬로 보는 경우는 셋 — 빈 authority(`file:///path`, VTE 규약상 localhost), `localhost`,
    /// 로컬 hostname과 일치. 비교는 **대소문자를 무시**하고(호스트명은 DNS 규약상 case-insensitive),
    /// **FQDN의 첫 `.` 앞 짧은 이름도 함께** 본다 — 셸은 `${HOST}`에 짧은 이름을 싣는데 로컬 이름은
    /// FQDN(`box.local`)으로 잡히는 비대칭이 흔해서, 그대로 비교하면 자기 자신을 원격으로 오인한다.
    ///
    /// 로컬 hostname을 못 얻었으면(빈 문자열) **원격으로 본다** — 두 오판의 피해가 대칭이 아니기 때문이다.
    /// 원격을 로컬로 보면 없는 디렉터리로 spawn하고 상대경로를 엉뚱하게 resolve하지만(지금의 결함),
    /// 로컬을 원격으로 보면 폴더줄에 host 접두가 붙고 cwd 상속이 꺼질 뿐이다. 단일 출처는
    /// docs/ssh-integration.md §9.2.
    pub fn hostIsLocal(host: []const u8, local_hostname: []const u8) bool {
        if (host.len == 0) return true;
        if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
        if (local_hostname.len == 0) return false;
        if (std.ascii.eqlIgnoreCase(host, local_hostname)) return true;
        // 짧은 이름 대 FQDN 보정은 **한쪽이 도메인 없는 이름일 때만** 허용한다. 양쪽 다 FQDN인데 전체가 다르면
        // 그것은 서로 다른 호스트다 — 첫 라벨만 비교하면 `box.corp.com`(원격)과 `box.home.net`(로컬)이 같아져
        // 원격 경로를 로컬 spawn에 넘긴다(이 함수가 막으려는 바로 그 결함).
        const host_dot = std.mem.indexOfScalar(u8, host, '.');
        const local_dot = std.mem.indexOfScalar(u8, local_hostname, '.');
        if (host_dot != null and local_dot != null) return false;
        const host_short = host[0 .. host_dot orelse host.len];
        const local_short = local_hostname[0 .. local_dot orelse local_hostname.len];
        return host_short.len > 0 and std.ascii.eqlIgnoreCase(host_short, local_short);
    }

    /// maru ssh 전용 OSC(5379 `ssh;<dest>`)로 받은 원격 세션 목적지. maru ssh로 접속한 세션이 아니면
    /// null이다. platform layer가 드롭 파일 업로드 시 cli.ssh.controlSocketPath(dest)로 control socket
    /// 경로를 계산하는 데 쓴다(docs/ssh-integration.md §4, 3단계).
    pub fn sshRemoteDest(self: *const TerminalCore) ?[]const u8 {
        return self.ssh_remote_dest;
    }

    /// OSC 0/2 창 제목을 설정한다(xterm ctlseqs). 빈 텍스트는 해제(null)로 본다 — `OSC 2 ; ST`로
    /// 앱이 제목을 지우면 cwd basename 폴백으로 돌아간다. OOM이면 제목 없이 둔다(텍스트는 어차피
    /// 그리드에 안 나오므로 손실 없음). parser.dispatchOsc(OSC 라우터)가 cross-file로 호출하므로 pub.
    pub fn setWindowTitle(self: *TerminalCore, text: []const u8) void {
        // 결과가 **실제로 바뀔 때만** free/realloc/bump한다 — 앱이 같은 제목을 매 프롬프트 재emit해도 헛 sync를 안 하게
        // (title_generation 무조건 bump는 P4-1의 "바뀐 term만 sync"를 무력화, code-review [0]). same=(옛 제목==새 텍스트,
        // 둘 다 null/빈이면 같음).
        const same = if (self.title) |old| std.mem.eql(u8, old, text) else text.len == 0;
        if (same) return;
        if (self.title) |old| self.allocator.free(old);
        self.title = if (text.len == 0) null else (self.allocator.dupe(u8, text) catch null); // 빈 텍스트=해제
        self.bumpTitleGeneration();
    }

    /// windowTitle() 결과(title 또는 cwd)가 바뀌었음을 알린다 — title_generation을 +1해 메인 syncAutoTitles가 그 term만
    /// lock+재복사하게 한다(P4-1, §12). **순서(ordering)**: `.monotonic`으로 충분하다 — 메인은 이 카운터를 오직 변경-감지
    /// (gen != last)로만 쓰고 title/cwd **버퍼 자체는 core_mutex 아래에서만** 읽으므로, 버퍼 가시성은 atomic이 아니라
    /// mutex가 보장한다(acquire/release는 load-bearing이 아님; code-review [7]). 최악은 한 tick 늦은 관측=benign.
    pub fn bumpTitleGeneration(self: *TerminalCore) void {
        _ = self.title_generation.fetchAdd(1, .monotonic);
    }

    /// 창 제목으로 보여줄 문자열(native 최소 — 우선순위 로직을 Zig가 소유한다). OSC 0/2로 앱이
    /// 지정한 제목이 있으면 그것을, 없으면 cwd의 basename(마지막 경로 요소)을 쓴다. 둘 다 없으면
    /// 빈 슬라이스(platform이 앱 이름 등으로 폴백). 반환은 core 소유 슬라이스(title 또는 cwd의
    /// 부분슬라이스)로 다음 OSC 0/2/7·RIS·destroy까지 유효하다.
    pub fn windowTitle(self: *const TerminalCore) []const u8 {
        if (self.title) |t| return t;
        const cwd = self.currentCwd();
        if (cwd.len == 0) return "";
        return std.fs.path.basename(cwd); // "/Users/me/proj" -> "proj", "/" -> ""
    }

    /// drain되지 않아도 메모리가 무한정 자라지 않게 하는 상한. 한 프롬프트 사이클은 A/B/C/D(+cwd)
    /// ~5개라 프레임마다 drain되면 닿을 일이 없고, 닿으면 새 이벤트를 버리고 overflow 플래그를 세운다.
    const shell_events_cap = 4096;

    /// 셸 의미 이벤트를 스트림에 기록한다(OSC 133/7 dispatch가 호출). cap을 넘거나 OOM이면 드롭하고
    /// overflow를 표시한다 — 조용히 잃지 않고 소비자(디버그 로그)가 드롭을 보고할 수 있게.
    pub fn recordShellEvent(self: *TerminalCore, event: types.ShellEvent) void {
        if (self.shell_events.items.len >= shell_events_cap) {
            self.shell_events_overflow = true;
            return;
        }
        self.shell_events.append(self.allocator, event) catch {
            self.shell_events_overflow = true;
        };
    }

    /// 기록된 셸 의미 이벤트 스트림(소비 후 `clearShellEvents`로 비운다). 테스트·디버그 로그·후속
    /// trace 직렬화가 같은 슬라이스를 읽는다 — 반환은 core 소유로 다음 clear/append/deinit까지 유효.
    pub fn shellEvents(self: *const TerminalCore) []const types.ShellEvent {
        return self.shell_events.items;
    }

    /// 이벤트 스트림을 비운다(용량은 유지해 재할당 없이 재사용). overflow 플래그도 내린다.
    pub fn clearShellEvents(self: *TerminalCore) void {
        self.shell_events.clearRetainingCapacity();
        self.shell_events_overflow = false;
    }

    /// 마지막 drain 이후 cap을 넘어 이벤트가 드롭됐는가(소비자가 손실을 보고할 수 있게).
    pub fn shellEventsOverflowed(self: *const TerminalCore) bool {
        return self.shell_events_overflow;
    }

    /// URI를 link_store에 intern하고 id(인덱스+1)를 돌려준다. 같은 URI는 한 번만 저장된다 —
    /// ls --hyperlink처럼 수백 셀이 같은 파일 URI를 가리켜도 문자열은 하나다.
    pub fn internLink(self: *TerminalCore, uri: []const u8) !u32 {
        if (self.link_ids.get(uri)) |id| return id;
        const owned = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned);
        const id: u32 = @intCast(self.link_store.items.len + 1);
        try self.link_store.append(self.allocator, owned);
        errdefer _ = self.link_store.pop();
        try self.link_ids.put(self.allocator, owned, id);
        return id;
    }

    /// 링크 id -> URI(없으면 null). selection.extractUrlAt(OSC 8 우선)이 cross-file 호출 — pub.
    pub fn linkUri(self: *const TerminalCore, id: u32) ?[]const u8 {
        if (id == 0 or id > self.link_store.items.len) return null;
        return self.link_store.items[id - 1];
    }

    /// cluster 본체(base 뒤 extra 코드포인트 배열)를 store에 intern하고 id(인덱스+1)를 돌려준다.
    /// link과 같이 **dedup**한다 — 같은 cluster는 한 번만 저장(grapheme_ids 해시맵). 같은 '한'을 천 번
    /// 찍어도 1 entry라 store가 셀 수가 아니라 distinct cluster 수만큼만 큰다. append-only.
    pub fn internGrapheme(self: *TerminalCore, cps: []const u21) !u32 {
        if (self.grapheme_ids.getContext(cps, .{})) |id| return id; // dedup: 같은 cluster 재사용
        const owned = try self.allocator.dupe(u21, cps);
        errdefer self.allocator.free(owned);
        const id: u32 = @intCast(self.grapheme_store.items.len + 1);
        try self.grapheme_store.append(self.allocator, owned);
        errdefer _ = self.grapheme_store.pop();
        try self.grapheme_ids.putContext(self.allocator, owned, id, .{}); // 키는 store가 소유한 owned
        return id;
    }

    /// 기존 cluster(id; 0이면 빈 것으로 취급) 뒤에 cp 하나를 덧붙인 새 cluster를 intern해 id를 돌려준다.
    /// internGrapheme를 거치므로 dedup된다(같은 결과 cluster면 기존 id 재사용). NFD 한글 자모가 음절에
    /// 차례로 붙을 때(writeCodepoint의 cluster 확장) 호출된다. screen.zig가 cross-file 호출 — pub.
    pub fn appendGraphemeCodepoint(self: *TerminalCore, id: u32, cp: u21) !u32 {
        const old: []const u21 = self.graphemeCluster(id) orelse &.{};
        // old ++ cp를 임시 버퍼에 만들어 intern(dedup). 이미 있는 cluster면 internGrapheme이 임시를
        // 안 쓰고 기존 id를 돌려준다(새 cluster일 때만 store가 복사 보관).
        const tmp = try self.allocator.alloc(u21, old.len + 1);
        defer self.allocator.free(tmp);
        @memcpy(tmp[0..old.len], old);
        tmp[old.len] = cp;
        return self.internGrapheme(tmp);
    }

    /// grapheme id -> cluster 본체(없으면 null). RowCodepoints(직렬화)·screen.writeCodepoint가
    /// cross-file 호출 — pub.
    pub fn graphemeCluster(self: *const TerminalCore, id: u32) ?[]const u21 {
        if (id == 0 or id > self.grapheme_store.items.len) return null;
        return self.grapheme_store.items[id - 1];
    }

    /// grapheme store를 비운다(RIS 등 하드 리셋 — 이후 셀이 다 지워져 grapheme_id가 가리킬 대상이
    /// 없다). clearLinkStore와 같은 자리에서 호출된다. dedup 맵도 함께 비운다(키가 store 메모리라 free 후).
    fn clearGraphemeStore(self: *TerminalCore) void {
        for (self.grapheme_store.items) |g| self.allocator.free(g);
        self.grapheme_store.clearRetainingCapacity();
        self.grapheme_ids.clearRetainingCapacity();
    }

    /// i번째 CSI 파라미터를 raw로 돌려준다(없으면 0). erase mode처럼 0이 유효값인 곳에 쓴다.
    /// param 저장소(csi_params/csi_param_count 필드)와 한 묶음이라 core 잔류. parser의 SGR/모드 dispatch
    /// (setPrivateModes·applySgr 등)와 screen이 cross-file 호출 — pub.
    pub fn csiRawParam(self: *const TerminalCore, i: usize) u16 {
        const count = @min(self.csi_param_count, max_csi_params);
        return if (i >= count) 0 else self.csi_params[i];
    }

    /// i번째 CSI 파라미터(없거나 0이면 default). cursor move처럼 0을 1로 보는 곳에 쓴다.
    /// param 저장소(csi_params 필드)와 한 묶음이라 core 잔류. parser의 dispatchCsi와 screen.cursorPosition
    /// (CUP/HVP)·setScrollRegion이 cross-file 호출 — pub.
    pub fn csiParam(self: *const TerminalCore, i: usize, default: u16) u16 {
        const value = self.csiRawParam(i);
        return if (value == 0) default else value;
    }

    /// focus reporting(DECSET 1004) 변화를 CSI I/O로 리포트. 본문: input_report.reportFocus.
    pub fn reportFocus(self: *TerminalCore, gained: bool) void {
        input_report.reportFocus(self, gained);
    }
    /// 마우스 이벤트를 활성 tracking/format으로 PTY에 리포트. 본문: input_report.reportMouse.
    pub fn reportMouse(self: *TerminalCore, button: u8, col: u16, row: u16, x_px: u16, y_px: u16, pressed: bool, motion: bool, mods: u8) void {
        input_report.reportMouse(self, button, col, row, x_px, y_px, pressed, motion, mods);
    }

    /// 호스트(PTY)로 보낼 응답 바이트를 버퍼에 적재한다(best-effort). osc.zig 등 목적별 host-reply 모듈이
    /// 호출하므로 pub다(구조와 파일 분리 — 같은 응답 버퍼를 단일 경로로 쓴다).
    pub fn appendResponse(self: *TerminalCore, bytes: []const u8) void {
        self.response.appendSlice(self.allocator, bytes) catch {}; // best-effort(OOM이면 응답 생략)
    }

    /// 아직 호스트(PTY)로 안 보낸 터미널 응답 바이트. app이 매 write 후 이걸 PTY로 쓰고 clearResponse한다.
    pub fn pendingResponse(self: *const TerminalCore) []const u8 {
        return self.response.items;
    }

    pub fn clearResponse(self: *TerminalCore) void {
        self.response.clearRetainingCapacity();
    }

    /// 그리드 크기 변경. 본문(reflow·스크롤백 push)은 screen.resize가 소유 — 외부(app/runtime·host·
    /// live_pty)가 core.resize를 점-호출하므로 facade 메서드로 남긴다(Zig dot-call 계약).
    pub fn resize(self: *TerminalCore, cols_in: u16, rows_in: u16) !void {
        return screen.resize(self, cols_in, rows_in);
    }

    /// 렌더용 snapshot. 본문은 screen.zig가 소유 — 외부(app/session/renderer)가 점-호출하므로 facade 메서드로 남긴다.
    pub fn snapshot(self: *const TerminalCore) types.RenderSnapshot {
        return screen.snapshot(self);
    }

    /// config `cursor.shape` 기본값 주입. 본문은 screen.zig(DECSCUSR와 같은 자리) — app/host가 점-호출하는
    /// 경계라 facade 메서드로 남긴다(resize·snapshot과 같은 규율).
    pub fn setDefaultCursorShape(self: *TerminalCore, shape: types.CursorShape) void {
        screen.setDefaultCursorShape(self, shape);
    }

    /// 뷰포트 합성 snapshot(스크롤 시 [스크롤백 ++ 활성] 윈도). IME preedit은 Surface projection이
    /// 이 base 위에 합성한다. 본문은 screen.zig 소유, facade 메서드.
    pub fn renderSnapshot(self: *TerminalCore) types.RenderSnapshot {
        return screen.renderSnapshot(self);
    }

    pub fn takeDirty(self: *TerminalCore) ?types.DirtyRegion {
        // renderer에는 "이번 변경 범위를 소비했다"는 명시적인 지점이 필요하다.
        // 이 함수가 없으면 모든 snapshot이 영원히 dirty처럼 보여서, dirty redraw
        // 테스트가 한 프레임의 변경 소비 여부를 증명할 수 없다.
        const region = self.dirty;
        self.dirty = null;
        return region;
    }

    pub fn clearDirty(self: *TerminalCore) void {
        // 테스트와 향후 renderer가 "이미 그린 상태"를 만들 때 쓴다.
        // dirty bookkeeping을 TerminalCore 안에 두면 renderer가 내부 상태를
        // 직접 고치는 구조로 새는 것을 막을 수 있다.
        self.dirty = null;
    }

    /// KeyEvent를 PTY 입력 바이트로 인코딩(현재 입력 모드 반영). 본문: input_report.encodeKey.
    pub fn encodeKey(self: *const TerminalCore, event: input.KeyEvent, buffer: *[input.encoded_key_buffer_len]u8) ![]const u8 {
        return input_report.encodeKey(self, event, buffer);
    }
    /// 현재 입력 인코딩 모드(DECCKM·kitty·keypad). 본문: input_report.encodeOptions.
    pub fn encodeOptions(self: *const TerminalCore) input.EncodeOptions {
        return input_report.encodeOptions(self);
    }

    pub fn dumpUtf8(self: *const TerminalCore, allocator: std.mem.Allocator) ![]u8 {
        // E2E assertions need a beginner-friendly way to inspect the screen.
        // This helper is deliberately not a renderer; it serializes cells into
        // plain text so tests can say "the screen contains hello" without
        // needing Metal, fonts, or screenshots.
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        for (0..self.size.rows) |row| {
            if (row != 0) try output.append(allocator, '\n');
            const row_start = self.index(row, 0);
            var codepoints: types.RowCodepoints = .{
                .cells = self.screen.cells[row_start..][0..self.size.cols],
                .graphemes = self.grapheme_store.items, // cluster 본체 무손실 복원(id→자모 전체)
            };
            while (codepoints.next()) |codepoint| {
                var buffer: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(codepoint, &buffer);
                try output.appendSlice(allocator, buffer[0..len]);
            }
        }

        return output.toOwnedSlice(allocator);
    }

    /// 활성 화면의 물리적 마지막 `max_rows`만 일반 텍스트로 직렬화한다. 관측/진단용 bounded API라 스크롤백과
    /// 전체 화면을 복사하지 않으며, UTF-8 codepoint 경계를 보존한 채 `max_bytes` 전에 멈춘다.
    pub fn dumpRecentUtf8(self: *const TerminalCore, allocator: std.mem.Allocator, max_rows: usize, max_bytes: usize) ![]u8 {
        return self.dumpRowsEndingAtUtf8(allocator, max_rows, max_bytes, self.size.rows);
    }

    /// 활성 화면의 마지막 **텍스트 콘텐츠**를 기준으로 `max_rows`만 직렬화한다. fullscreen TUI가 resize 뒤 아래 행을
    /// 비워 두는 경우(실측 Codex)에도 observer가 물리적 bottom 공백만 읽지 않게 하는 전용 API다. trailing blank 탐색은
    /// cell scan일 뿐 복사하지 않고, 실제 UTF-8 직렬화는 dumpRecentUtf8와 같은 행·바이트 상한을 지킨다.
    pub fn dumpRecentTextUtf8(self: *const TerminalCore, allocator: std.mem.Allocator, max_rows: usize, max_bytes: usize) ![]u8 {
        var last_row_exclusive: usize = self.size.rows;
        const scan_floor = last_row_exclusive - @min(last_row_exclusive, recent_text_blank_scan_rows);
        var found_text = false;
        while (last_row_exclusive > scan_floor) {
            const row_start = self.index(last_row_exclusive - 1, 0);
            const cells = self.screen.cells[row_start..][0..self.size.cols];
            var has_text = false;
            for (cells) |cell| {
                if (cell.codepoint != ' ' and cell.codepoint != 0) { // 안 쓴 칸(0)도 빈칸이다
                    has_text = true;
                    break;
                }
            }
            if (has_text) {
                found_text = true;
                break;
            }
            last_row_exclusive -= 1;
        }
        // scan 상한 안에 text anchor가 없으면 물리적 bottom을 써 오래된 위쪽 문구를 현재 근거로 끌어오지 않는다.
        if (!found_text) last_row_exclusive = self.size.rows;
        return self.dumpRowsEndingAtUtf8(allocator, max_rows, max_bytes, last_row_exclusive);
    }

    fn dumpRowsEndingAtUtf8(self: *const TerminalCore, allocator: std.mem.Allocator, max_rows: usize, max_bytes: usize, last_row_exclusive: usize) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        if (max_rows == 0 or max_bytes == 0) return output.toOwnedSlice(allocator);

        const worst_row_bytes = @as(usize, self.size.cols) *| 4 +| 1;
        const byte_bounded_rows = @max(1, max_bytes / @max(1, worst_row_bytes));
        const selected_rows = @min(last_row_exclusive, @min(max_rows, byte_bounded_rows));
        const first_row = last_row_exclusive - selected_rows;
        for (first_row..last_row_exclusive) |row| {
            if (row != first_row) {
                if (output.items.len == max_bytes) break;
                try output.append(allocator, '\n');
            }
            const row_start = self.index(row, 0);
            var codepoints: types.RowCodepoints = .{
                .cells = self.screen.cells[row_start..][0..self.size.cols],
                .graphemes = self.grapheme_store.items,
            };
            while (codepoints.next()) |codepoint| {
                var buffer: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(codepoint, &buffer);
                if (output.items.len + len > max_bytes) return output.toOwnedSlice(allocator);
                try output.appendSlice(allocator, buffer[0..len]);
            }
        }
        return output.toOwnedSlice(allocator);
    }

    /// 행·열 → cells 1차원 인덱스. screen.zig 활성 화면 연산(lastCellIs*)도 cross-file 호출 — pub.
    pub fn index(self: *const TerminalCore, row: usize, col: usize) usize {
        return row * self.size.cols + col;
    }
};

/// grid 셀 수(rows×cols). screen.enterAltScreen(alt 버퍼 할당)이 cross-file 호출 — pub.
pub fn cellCount(size: types.Size) usize {
    return @as(usize, size.cols) * @as(usize, size.rows);
}

/// grid를 최소 cols>=2, rows>=1로 맞춘다. 한 cell 글자 모델은 wide glyph(2칸)의 continuation을
/// 옆 칸에 쓰므로 1칸짜리 grid는 마지막 칸에서 col+1 OOB를 부른다. init/resize에서 항상 이 최소
/// 크기를 보장해 그 degenerate 입력을 원천 차단한다(1칸 터미널은 실사용도 없다). 그래서 putCell은
/// cols>=2를 가정하고 wide glyph가 줄 끝에 안 들어가면 단순히 다음 줄로 넘기면 된다. PTY winsize와
/// grid 계산(gridFromBacking)이 같은 최소 크기를 쓰도록 pub으로 노출해 불변식을 한 곳에 둔다.
pub fn clampGridSize(size: types.Size) types.Size {
    return .{ .cols = @max(size.cols, 2), .rows = @max(size.rows, 1) };
}

/// 화면 전체 dirty 영역. screen.eraseInDisplay(ED 2/3)이 cross-file 호출 — pub.
pub fn fullDirty(size: types.Size) ?types.DirtyRegion {
    if (size.rows == 0 or size.cols == 0) return null;
    return .{ .start_row = 0, .end_row = size.rows - 1 };
}

test "terminal core stores size and resizes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 100, .rows = 30 });
    defer core.deinit();

    try std.testing.expectEqual(@as(u16, 100), core.snapshot().size.cols);

    try core.resize(120, 40);
    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 120), snapshot.size.cols);
    try std.testing.expectEqual(@as(u16, 40), snapshot.size.rows);
    try std.testing.expectEqual(@as(usize, 120 * 40), snapshot.cells.len);
}

test "OSC 5379 ssh: maru ssh 원격 dest를 저장하고 잘못된 payload는 무시한다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try std.testing.expect(core.sshRemoteDest() == null); // 초기엔 로컬(미수신)
    try core.write("\x1b]5379;ssh;user@host\x07"); // maru ssh 래퍼가 exec 직전 emit하는 통지
    try std.testing.expectEqualStrings("user@host", core.sshRemoteDest().?);
    try core.write("\x1b]5379;other;x\x07"); // 알 수 없는 서브커맨드 → 무시(기존 유지)
    try std.testing.expectEqualStrings("user@host", core.sshRemoteDest().?);
    try core.write("\x1b]5379;ssh;\x07"); // 빈 dest → 무시(기존 유지)
    try std.testing.expectEqualStrings("user@host", core.sshRemoteDest().?);
    try core.write("\x1b]5379;ssh;admin@box\x07"); // 새 dest로 갱신
    try std.testing.expectEqualStrings("admin@box", core.sshRemoteDest().?);
    try core.write("\x1b]5379;ssh-end\x07"); // foreground ssh 종료 → 로컬 shell 복귀
    try std.testing.expect(core.sshRemoteDest() == null);
    try core.write("\x1b]5379;ssh-end\x07"); // 중복 clear 멱등
    try std.testing.expect(core.sshRemoteDest() == null);
}

test "terminal core writes process-like text into cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();

    try core.write("hello\nmaru");

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "maru") != null);
    try std.testing.expectEqual(@as(u16, 1), core.snapshot().cursor.row);
}

test "findMatches: 대소문자 무시 부분일치 + 비겹침 + 절대 좌표" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    try core.write("alpha\r\nbeta\r\nalpha gamma");

    var matches: std.ArrayList(types.Match) = .empty;
    defer matches.deinit(std.testing.allocator);

    // "alpha" 2곳: row0 col0, row2 col0. end.col = 4('alpha'=5칸 0..4).
    try core.findMatches(std.testing.allocator, "alpha", &matches);
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0].start.row);
    try std.testing.expectEqual(@as(u16, 0), matches.items[0].start.col);
    try std.testing.expectEqual(@as(u16, 4), matches.items[0].end.col);
    try std.testing.expectEqual(@as(usize, 2), matches.items[1].start.row);

    // 대소문자 무시: 같은 2곳.
    try core.findMatches(std.testing.allocator, "ALPHA", &matches);
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);

    // 없는 needle / 빈 needle → 0.
    try core.findMatches(std.testing.allocator, "zzz", &matches);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
    try core.findMatches(std.testing.allocator, "", &matches);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "findMatches: 유니코드 대소문자 무시(Latin-1·Greek·Cyrillic foldCase)" {
    // foldCase 직접 — 각 블록 대문자→소문자, 비-글자/미덮음 블록은 그대로.
    try std.testing.expectEqual(@as(u21, 'a'), selection.foldCase('A'));
    try std.testing.expectEqual(@as(u21, 0x00E9), selection.foldCase(0x00C9)); // É→é
    try std.testing.expectEqual(@as(u21, 0x00F1), selection.foldCase(0x00D1)); // Ñ→ñ
    try std.testing.expectEqual(@as(u21, 0x00D7), selection.foldCase(0x00D7)); // × 그대로(글자 아님)
    try std.testing.expectEqual(@as(u21, 0x03B1), selection.foldCase(0x0391)); // Α→α
    try std.testing.expectEqual(@as(u21, 0x03C9), selection.foldCase(0x03A9)); // Ω→ω
    try std.testing.expectEqual(@as(u21, 0x0430), selection.foldCase(0x0410)); // А→а
    try std.testing.expectEqual(@as(u21, 0x044F), selection.foldCase(0x042F)); // Я→я
    try std.testing.expectEqual(@as(u21, 0x0450), selection.foldCase(0x0400)); // Ѐ→ѐ
    try std.testing.expectEqual(@as(u21, 0x0100), selection.foldCase(0x0100)); // Ā 미덮음(Latin Ext-A — 그대로)

    // findMatches 통합 — 악센트/스크립트 대소문자 무시(코드포인트는 \u{}로 명시해 편집기 정규화 회피).
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    try core.write("CAF\u{00C9}\r\n\u{0391}\u{039B}\u{03A6}\u{0391}\r\n\u{041F}\u{0420}\u{0418}\u{0412}\u{0415}\u{0422}");
    var matches: std.ArrayList(types.Match) = .empty;
    defer matches.deinit(std.testing.allocator);

    try core.findMatches(std.testing.allocator, "caf\u{00E9}", &matches); // café ↔ CAFÉ
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try core.findMatches(std.testing.allocator, "\u{03B1}\u{03BB}\u{03C6}\u{03B1}", &matches); // αλφα ↔ ΑΛΦΑ
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try core.findMatches(std.testing.allocator, "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", &matches); // привет ↔ ПРИВЕТ
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
}

test "findMatches: soft-wrap 경계를 넘는 매치" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("abcdefghij"); // 8칸 auto-wrap → row0 "abcdefgh"(wrapped), row1 "ij"

    var matches: std.ArrayList(types.Match) = .empty;
    defer matches.deinit(std.testing.allocator);
    try core.findMatches(std.testing.allocator, "ghij", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0].start.row); // 'g' = row0 col6
    try std.testing.expectEqual(@as(u16, 6), matches.items[0].start.col);
    try std.testing.expectEqual(@as(usize, 1), matches.items[0].end.row); // 'j' = row1 col1
    try std.testing.expectEqual(@as(u16, 1), matches.items[0].end.col);
}

test "findMatches: alt screen에선 현재 화면만 검색한다(primary 스크롤백 제외)" {
    // alt screen(vim/less/Claude/Codex)에선 활성 스크롤백이 cap=0인 빈 인스턴스라 primary 스크롤백이
    // 검색 범위에 안 들어가고(sb.count==0), alt는 화면 밖 과거를 스크롤백에 안 쌓으므로, findMatches는
    // 현재 alt 화면만 검색한다(Ghostty ActiveSearch와 같은 범위). 이게 깨지면 "찾았지만 못 가는" 매치가
    // 카운터에 섞여 ⌘G 네비가 헛돈다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();

    // primary에 needle "alpha"를 출력한 뒤 화면(3행) 밖 스크롤백으로 밀어낸다.
    try core.write("alpha\r\n");
    var i: usize = 0;
    while (i < 6) : (i += 1) try core.write("filler\r\n");
    try std.testing.expect(core.screen.sb.count > 0);

    var matches: std.ArrayList(types.Match) = .empty;
    defer matches.deinit(std.testing.allocator);

    // primary에선 스크롤백의 alpha가 잡힌다(대조군 — 스크롤백 포함 검색).
    try core.findMatches(std.testing.allocator, "alpha", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);

    // alt screen 진입(DECSET 1049: alt 버퍼 + 화면 클리어) 후 alt 화면에 다른 텍스트.
    try core.write("\x1b[?1049h");
    try std.testing.expect(core.alt_active);
    try core.write("bravo");

    // alt에선 primary 스크롤백의 alpha는 검색되지 않는다(현재 화면 밖이므로 제외).
    try core.findMatches(std.testing.allocator, "alpha", &matches);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
    // alt 현재 화면의 bravo는 검색된다(현재 화면이 검색 가능한 전부).
    try core.findMatches(std.testing.allocator, "bravo", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);

    // primary 복귀하면(alt 버퍼만 버려짐) 다시 스크롤백의 alpha가 잡힌다.
    try core.write("\x1b[?1049l");
    try std.testing.expect(!core.alt_active);
    try core.findMatches(std.testing.allocator, "alpha", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
}

test "scrollToAbs: 스크롤백 매치를 뷰포트로 가져온다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    var i: usize = 0;
    while (i < 10) : (i += 1) try core.write("line\r\n"); // 화면(3행)보다 많이 써 스크롤백 생성
    try std.testing.expect(core.screen.sb.count > 0);

    // 맨 위(abs 0)로 → 과거를 본다(view_offset > 0).
    core.scrollToAbs(0);
    try std.testing.expect(core.viewOffset() > 0);
    // 바닥(활성 화면 마지막 행)으로 → view_offset 0.
    core.scrollToAbs(core.screen.sb.count + core.size.rows - 1);
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());
}

test "terminal core preserves UTF-8 split across process read boundaries" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();

    // PTY reads are byte streams, not UTF-8 string messages. A Korean
    // character can arrive as one byte in one read and the remaining bytes in
    // the next read; TerminalCore owns this tail buffering so PTY code does
    // not need to understand text encoding.
    const korean = "한";
    try core.write(korean[0..1]);
    try std.testing.expectEqual(@as(u16, 0), core.snapshot().cursor.col);

    try core.write(korean[1..]);
    try core.write("글");

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "한글") != null);
    try std.testing.expectEqual(@as(u16, 0), core.snapshot().cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.snapshot().cursor.col);
}

test "terminal core preserves four-byte UTF-8 split across multiple writes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();

    const rocket = "🚀";
    try core.write("go ");
    try core.write(rocket[0..1]);
    try core.write(rocket[1..3]);
    try core.write(rocket[3..]);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "go 🚀") != null);
    try std.testing.expectEqual(@as(u16, 5), core.snapshot().cursor.col);
}

test "terminal core stores wide characters with continuation cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // A terminal grid advances by cells, not by UTF-8 byte length or font
    // advance. Korean/CJK characters occupy two cells, and the second cell
    // must be marked as a continuation so cursor movement, snapshots, and the
    // future renderer do not treat it as a separate printable character.
    try core.write("A한B");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 4), snapshot.cursor.col);
    try std.testing.expectEqual(@as(u21, 'A'), snapshot.cells[0].codepoint);
    try std.testing.expectEqual(@as(u2, 1), snapshot.cells[0].width);
    try std.testing.expect(!snapshot.cells[0].continuation);
    try std.testing.expectEqual(@as(u21, '한'), snapshot.cells[1].codepoint);
    try std.testing.expectEqual(@as(u2, 2), snapshot.cells[1].width);
    try std.testing.expect(!snapshot.cells[1].continuation);
    try std.testing.expect(snapshot.cells[2].continuation);
    try std.testing.expectEqual(@as(u2, 0), snapshot.cells[2].width);
    try std.testing.expectEqual(@as(u21, 'B'), snapshot.cells[3].codepoint);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "A한B") != null);
}

/// 테스트 보조: 셀의 grapheme cluster 본체(base 뒤 extra 코드포인트)가 expected와 같은지 확인한다.
/// grapheme_id==0이면 빈 슬라이스. combining 필드를 없앤(pure-B) 뒤 단언을 store 기반으로 통일한다.
fn expectCluster(c: *const TerminalCore, grapheme_id: u32, expected: []const u21) !void {
    const cluster = c.graphemeCluster(grapheme_id) orelse &.{};
    try std.testing.expectEqualSlices(u21, expected, cluster);
}

test "terminal core attaches a combining mark without advancing the cursor" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // Combining marks are zero-width. They belong to the previous printable
    // cell and must not move the cursor, otherwise prompts and editor grids
    // drift when accents or other marks appear.
    try core.write("e\u{0301}x");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 2), snapshot.cursor.col);
    try std.testing.expectEqual(@as(u21, 'e'), snapshot.cells[0].codepoint);
    try expectCluster(&core, snapshot.cells[0].grapheme_id, &.{0x0301});
    try std.testing.expectEqual(@as(u21, 'x'), snapshot.cells[1].codepoint);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "e\u{0301}x") != null);
}

test "terminal core attaches a combining mark to a base char in the last column" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // Without autowrap the cursor parks *on* the base glyph when it lands in
    // the last column, so deriving the base from cursor-1 attached the accent
    // to the previous cell. The mark must land on the actual last-printed cell.
    try core.write("abe\u{0301}");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u21, 'b'), snapshot.cells[1].codepoint);
    try expectCluster(&core, snapshot.cells[1].grapheme_id, &.{});
    try std.testing.expectEqual(@as(u21, 'e'), snapshot.cells[2].codepoint);
    try expectCluster(&core, snapshot.cells[2].grapheme_id, &.{0x0301});

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "abe\u{0301}") != null);
}

test "terminal core drops a combining mark with no base on the current row" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    // A line feed ends the grapheme run and does not reset the column, so the
    // cursor sits over a blank cell on the new row. A combining mark there has
    // no base and must be dropped instead of accenting that blank cell.
    try core.write("A\n\u{0301}");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u21, 'A'), snapshot.cells[0].codepoint);
    try expectCluster(&core, snapshot.cells[0].grapheme_id, &.{});
    for (snapshot.cells) |cell| try std.testing.expectEqual(@as(u32, 0), cell.grapheme_id);
}

test "NFD Hangul: conjoining L+V+T merges into one 2-cell syllable (GB6/7/8)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // macOS 파일명은 NFD라 `ls`가 '한'을 초성 U+1112 + 중성 U+1161 + 종성 U+11AB로 보낸다. 안
    // 묶으면 자모가 셀마다 흩어지고 폭이 2배(초성만 wide)가 된다 — 한 음절 cluster(2칸)로 묶는다.
    try core.write("\u{1112}\u{1161}\u{11AB}");

    const s = core.snapshot();
    try std.testing.expectEqual(@as(u16, 2), s.cursor.col); // 음절 1개 = 2칸 advance(완성형과 동일)
    try std.testing.expectEqual(@as(u21, 0x1112), s.cells[0].codepoint); // base=초성
    try std.testing.expectEqual(@as(u2, 2), s.cells[0].width);
    try std.testing.expect(s.cells[1].continuation);
    try std.testing.expectEqual(@as(u2, 0), s.cells[1].width);
    // 중성·종성은 store cluster 본체로 무손실 저장(base 뒤 [중성, 종성]).
    try std.testing.expect(s.cells[0].grapheme_id != 0);
    try expectCluster(&core, s.cells[0].grapheme_id, &.{ 0x1161, 0x11AB });

    // dump 무손실: 원본 NFD 자모 3개가 그대로 복원된다(클립보드·재출력 — 잘림 금지).
    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{1112}\u{1161}\u{11AB}") != null);
}

test "NFD Hangul: '한글' splits into two syllable clusters across 4 columns" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();

    // '한글' NFD = (ㅎㅏㄴ)(ㄱㅡㄹ). 종성 다음 새 초성에서 음절 경계가 끊겨야 한다(GB8은 T×T만,
    // T×L은 boundary). 두 음절이 각각 2칸씩 총 4칸을 차지한다.
    try core.write("\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}");

    const s = core.snapshot();
    try std.testing.expectEqual(@as(u16, 4), s.cursor.col);
    try std.testing.expectEqual(@as(u21, 0x1112), s.cells[0].codepoint); // 한
    try std.testing.expectEqual(@as(u2, 2), s.cells[0].width);
    try std.testing.expect(s.cells[1].continuation);
    try std.testing.expectEqual(@as(u21, 0x1100), s.cells[2].codepoint); // 글 — 새 음절(경계)
    try std.testing.expectEqual(@as(u2, 2), s.cells[2].width);
    try std.testing.expect(s.cells[3].continuation);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}") != null);
}

test "NFD Hangul: L+V without a final consonant stores the single extra in grapheme_store (pure-B)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // '가' NFD = ㄱ(U+1100) + ㅏ(U+1161), 종성 없음. extra 1개도 grapheme_store에 담는다(pure-B 단일
    // 출처 — combining 그림자 폐지). base=초성, width 2, cluster 본체=[중성].
    try core.write("\u{1100}\u{1161}");

    const s = core.snapshot();
    try std.testing.expectEqual(@as(u16, 2), s.cursor.col);
    try std.testing.expectEqual(@as(u21, 0x1100), s.cells[0].codepoint);
    try std.testing.expectEqual(@as(u2, 2), s.cells[0].width);
    try std.testing.expect(s.cells[0].grapheme_id != 0);
    try expectCluster(&core, s.cells[0].grapheme_id, &.{0x1161});

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{1100}\u{1161}") != null);
}

test "NFD Hangul: a conjoining vowel after a non-Hangul base is its own cell (boundary)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // 'A' 다음 중성(U+1161) — A는 한글이 아니라(hangulClass=none) cluster로 묶이지 않는다.
    // 잘못 묶으면 무관한 글자가 자모를 빨아들인다. 중성은 별도 셀로 떨어진다.
    try core.write("A\u{1161}");

    const s = core.snapshot();
    try std.testing.expectEqual(@as(u21, 'A'), s.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0), s.cells[0].grapheme_id);
    try std.testing.expectEqual(@as(u21, 0x1161), s.cells[1].codepoint); // 별도 셀
}

test "multi-combining: 둘째 mark부터 grapheme_store에 누적돼 무손실 (HG2b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // e + combining acute(U+0301) + combining dot-below(U+0323). 예전엔 단일 combining 슬롯이라
    // 마지막(U+0323)만 남아 U+0301을 dump·복사에서 잃었다 — 이제 둘째 mark부터 store에 누적해 무손실.
    try core.write("e\u{0301}\u{0323}x");

    const s = core.snapshot();
    try std.testing.expectEqual(@as(u16, 2), s.cursor.col); // combining mark는 0폭 — e,x만 advance
    try std.testing.expectEqual(@as(u21, 'e'), s.cells[0].codepoint);
    // store가 두 mark 전부 무손실 보존(base 뒤 [acute, dot-below]).
    try std.testing.expect(s.cells[0].grapheme_id != 0);
    try expectCluster(&core, s.cells[0].grapheme_id, &.{ 0x0301, 0x0323 });

    // dump 무손실: e + 두 결합 마크 + x가 모두 복원된다(예전엔 U+0301이 사라졌다).
    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "e\u{0301}\u{0323}x") != null);
}

test "bare ZWJ(U+200D)는 NFD cluster에 흡수되지 않고 제 셀을 유지한다 (리뷰 #2 회귀)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // ZWJ는 conjoining 자모(U+1100~U+11FF) 범위 밖이라 NFD 흡수 대상이 아니다. extendsCluster는
    // GB9로 ZWJ를 true로 보지만 폭이 1이라, 흡수했다면 'a' 셀에 0폭으로 붙어 커서가 2칸만 전진했을
    // 것이다. 흡수하지 않으므로 'a','ZWJ','b' 세 셀(커서 3) — NFD 한글 작업이 ZWJ 동작을 안 바꾼다.
    try core.write("a\u{200D}b");

    const s = core.snapshot();
    try std.testing.expectEqual(@as(u16, 3), s.cursor.col);
    try std.testing.expectEqual(@as(u21, 'a'), s.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0), s.cells[0].grapheme_id); // ZWJ가 'a'에 안 붙음
    try std.testing.expectEqual(@as(u21, 0x200D), s.cells[1].codepoint); // ZWJ는 제 셀
    try std.testing.expectEqual(@as(u21, 'b'), s.cells[2].codepoint);
}

test "ambiguous_wide makes circled numbers occupy two cells (advance 2) with a continuation" {
    {
        // 기본 narrow: ③는 1칸, 커서 advance 1(Ghostty/xterm.js 호환).
        var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
        defer core.deinit();
        try core.write("③");
        const s = core.snapshot();
        try std.testing.expectEqual(@as(u2, 1), s.cells[0].width);
        try std.testing.expectEqual(@as(u16, 1), s.cursor.col);
    }
    {
        // wide: ③는 2칸(continuation) + 커서 advance 2 — CJK wide와 같은 경로(text.ambiguous-width=wide).
        var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
        defer core.deinit();
        core.ambiguous_wide = true; // write 전에 설정(putCell이 읽음)
        try core.write("③X");
        const s = core.snapshot();
        try std.testing.expectEqual(@as(u21, 0x2462), s.cells[0].codepoint);
        try std.testing.expectEqual(@as(u2, 2), s.cells[0].width);
        try std.testing.expect(s.cells[1].continuation);
        try std.testing.expectEqual(@as(u21, 'X'), s.cells[2].codepoint); // ③가 2칸이라 X는 col2
        try std.testing.expectEqual(@as(u16, 3), s.cursor.col); // ③(2) + X(1)
    }
}

test "terminal core backspace moves exactly one column even over a wide continuation" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // BS는 정확히 1칸이다(ECMA-48, xterm.js 동일). 셸은 wide 글자에 BS를 두 번 보내므로,
    // continuation을 건너뛰는 "친절"은 셸 계산과 한 칸 어긋나 지우기가 프롬프트를 침범한다
    // (라이브 한글 삭제에서 실제 발생). BS 한 번이면 커서는 continuation 칸(col 1)에 서고,
    // 그 자리 쓰기는 clearCellForWrite가 base/continuation을 함께 정리해 글자가 깨지지 않는다.
    try core.write("한\u{08}X");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u21, 'X'), snapshot.cells[1].codepoint);
    try std.testing.expect(!snapshot.cells[0].continuation);
    try std.testing.expect(!snapshot.cells[1].continuation);
    try std.testing.expectEqual(@as(u16, 2), snapshot.cursor.col);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    // base 반쪽(한)은 continuation 자리에 X를 쓰며 정리된다 — half-glyph가 남지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, text, "한") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "X") != null);
}

test "terminal core tab expansion stops at the row edge" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();

    // This test protects the root cause of a common terminal-core failure:
    // cursor movement that cannot advance must not leave a control sequence in
    // an infinite loop. Full wrap behavior will be specified separately.
    try core.write("a\t");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 0), snapshot.cursor.row);
    try std.testing.expectEqual(@as(u16, 7), snapshot.cursor.col);
}

test "terminal core lets renderer consume dirty region once" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    const initial_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), initial_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 1), initial_dirty.end_row);
    try std.testing.expect(core.takeDirty() == null);

    try core.write("x");

    const next_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), next_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 0), next_dirty.end_row);
    try std.testing.expect(core.snapshot().dirty == null);
}

test "terminal core leaves frame clean when a cursor-only control does not move" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // At column 0 a carriage return and a backspace change nothing: the cursor
    // is already there. markCursorMoveDirty must early-return so the renderer
    // does not redraw a row whose pixels are unchanged.
    core.clearDirty();
    try core.write("\r");
    try std.testing.expect(core.takeDirty() == null);

    core.clearDirty();
    try core.write("\x08");
    try std.testing.expect(core.takeDirty() == null);
}

test "terminal core marks cursor-only movement dirty for cursor overlay redraw" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    // Carriage return changes only the cursor position. It still needs a
    // dirty row because the renderer must erase the old cursor overlay and
    // draw the new one even when no cell text changed.
    try core.write("AB");
    core.clearDirty();
    try core.write("\r");

    const cr_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), cr_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 0), cr_dirty.end_row);
    try std.testing.expectEqual(@as(u16, 0), core.snapshot().cursor.col);

    // Backspace is the same class of visual change: the glyph grid can stay
    // intact while the cursor overlay moves one cell left.
    try core.write("AB");
    core.clearDirty();
    try core.write("\x08");

    const bs_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), bs_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 0), bs_dirty.end_row);
    try std.testing.expectEqual(@as(u16, 1), core.snapshot().cursor.col);
}

test "terminal core marks the TAB cursor move dirty (HT cursor overlay redraw)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();

    // HT(tab) moves only the cursor to the next tab stop, leaving cell text intact —
    // like CR/BS it must still dirty the cursor row so the renderer erases the old
    // cursor overlay and draws the new one. Before the fix writeTab moved the cursor
    // without calling markCursorMoveDirty, so this row stayed clean (takeDirty()==null).
    core.clearDirty();
    try core.write("\t");

    const tab_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), tab_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 0), tab_dirty.end_row);
    try std.testing.expectEqual(@as(u16, 8), core.snapshot().cursor.col);
}

test "terminal core: TAB breaks the grapheme run so a following combining mark is dropped" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();

    // Print 'a', HT to the next tab stop, then a combining acute accent (U+0301). The tab clears
    // last_print (the grapheme-continuation anchor), so the mark has no base on the current run and
    // is dropped — it must NOT attach to the already-committed 'a' at col 0. This mirrors CR/LF/BS,
    // which all clear last_print. Before the fix the mark wrongly attached to the 'a' cluster at col 0.
    try core.write("a\t\u{0301}");

    try std.testing.expectEqual(@as(u32, 0), core.screen.cells[0].grapheme_id);
}

test "terminal core marks old and new cursor rows dirty across line feed" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();

    // A line feed moves the cursor to a different row without necessarily
    // changing cell text. Both rows are dirty because one loses the cursor
    // overlay and the other gains it.
    try core.write("A");
    core.clearDirty();
    try core.write("\n");

    const dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), dirty.start_row);
    try std.testing.expectEqual(@as(u16, 1), dirty.end_row);
    try std.testing.expectEqual(@as(u16, 1), core.snapshot().cursor.row);
}

test "SGR escape sequences are interpreted, not printed as text" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 1 });
    defer core.deinit();

    // The shell prompt problem: color codes must not show as literal "[31m" text.
    try core.write("\x1b[31mhi\x1b[0m");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi        ", dump);
}

test "SGR sets the pen style stamped onto written cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b[1;4;31mA");
    const cell = core.screen.cells[core.index(0, 0)];
    try std.testing.expectEqual(@as(u21, 'A'), cell.codepoint);
    try std.testing.expect(cell.style.bold);
    try std.testing.expect(cell.style.underline);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, cell.style.foreground);
}

test "SGR 9/29 toggle strikethrough on the pen stamped onto cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // SGR 9(crossed-out) → A는 strikethrough, SGR 29(not crossed-out) → B는 아님.
    // 베이스: ECMA-48 SGR 9/29, xterm ctlseqs 동일. underline(4)과 독립 비트라 같이 켤 수 있다.
    try core.write("\x1b[9mA\x1b[29mB");
    const a = core.screen.cells[core.index(0, 0)];
    const b = core.screen.cells[core.index(0, 1)];
    try std.testing.expect(a.style.strikethrough);
    try std.testing.expect(!b.style.strikethrough);

    // SGR 0(reset)은 strikethrough도 끈다(전체 리셋이 pen을 기본값으로).
    try core.write("\x1b[9mC\x1b[0mD");
    try std.testing.expect(core.screen.cells[core.index(0, 2)].style.strikethrough);
    try std.testing.expect(!core.screen.cells[core.index(0, 3)].style.strikethrough);
}

test "SGR 53/55 toggle overline on the pen stamped onto cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // SGR 53(overlined) → A는 overline, SGR 55(not overlined) → B는 아님. 베이스: ECMA-48 SGR 53/55,
    // xterm ctlseqs. strikethrough/underline과 독립 비트라 같이 켤 수 있다.
    try core.write("\x1b[53mA\x1b[55mB");
    try std.testing.expect(core.screen.cells[core.index(0, 0)].style.overline);
    try std.testing.expect(!core.screen.cells[core.index(0, 1)].style.overline);

    // SGR 0(reset)은 overline도 끈다(전체 리셋이 pen을 기본값으로).
    try core.write("\x1b[53mC\x1b[0mD");
    try std.testing.expect(core.screen.cells[core.index(0, 2)].style.overline);
    try std.testing.expect(!core.screen.cells[core.index(0, 3)].style.overline);
}

test "SGR 2/22 toggle dim, and 22 also clears bold (ECMA-48 normal intensity)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // SGR 2(faint) → A는 dim. 같은 셀에 bold(1)도 켜 두고, SGR 22(normal intensity)가 bold와 dim을
    // 둘 다 끄는지(ECMA-48) B에서 확인한다.
    try core.write("\x1b[1;2mA\x1b[22mB");
    const a = core.screen.cells[core.index(0, 0)];
    const b = core.screen.cells[core.index(0, 1)];
    try std.testing.expect(a.style.dim);
    try std.testing.expect(a.style.bold);
    try std.testing.expect(!b.style.dim);
    try std.testing.expect(!b.style.bold);

    // SGR 0(reset)도 dim을 끈다.
    try core.write("\x1b[2mC\x1b[0mD");
    try std.testing.expect(core.screen.cells[core.index(0, 2)].style.dim);
    try std.testing.expect(!core.screen.cells[core.index(0, 3)].style.dim);
}

test "SGR reset returns the pen to default for following cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b[1;31mA\x1b[0mB");
    const a = core.screen.cells[core.index(0, 0)];
    const b = core.screen.cells[core.index(0, 1)];
    try std.testing.expect(a.style.bold);
    try std.testing.expect(!b.style.bold);
    try std.testing.expectEqual(types.Color.default, b.style.foreground);
}

test "SGR 256-color and rgb extended forms set the foreground" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b[38;5;200mA");
    try std.testing.expectEqual(types.Color{ .indexed = 200 }, core.screen.cells[core.index(0, 0)].style.foreground);

    try core.write("\x1b[38;2;10;20;30mB");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.screen.cells[core.index(0, 1)].style.foreground,
    );
}

test "CSI cursor position moves the cursor with 1-based params" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();

    try core.write("\x1b[3;5H");
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.screen.cursor.col);

    // A bare CSI H homes the cursor.
    try core.write("\x1b[H");
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
}

test "CSI K erases from the cursor to the end of the line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    try core.write("abcde");
    // Column 3 (1-based) is index 2, then erase to end of line.
    try core.write("\x1b[3G\x1b[K");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("ab   ", dump);
}

test "CSI 2J clears the whole screen" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 2 });
    defer core.deinit();

    try core.write("ab\ncd");
    try core.write("\x1b[2J");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("   \n   ", dump);
}

test "clearScreen at the shell prompt wipes screen+scrollback, homes cursor, and requests redraw" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    // rows=3보다 많은 줄 → 스크롤백 생성.
    try core.write("l1\nl2\nl3\nl4\n");
    try std.testing.expect(core.scrollbackLen() > 0);
    // 셸 프롬프트 표시(OSC 133 A→B = prompt→input). semantic_state=.input → isPromptish.
    try core.write("\x1b]133;A\x1b\\");
    try core.write("\x1b]133;B\x1b\\");

    const redraw = core.clearScreen();
    try std.testing.expect(redraw); // 프롬프트 → 호출자가 ^L(form-feed)로 프롬프트 재그림
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // 스크롤백 비움
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row); // 커서 홈
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("    \n    \n    ", dump); // 4×3 전부 공백
}

test "clearScreen on the alternate screen is a no-op and does not request redraw" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?1049h"); // alt 진입(vim/less 류) — 앱이 화면 소유
    try core.write("vi");
    const redraw = core.clearScreen();
    try std.testing.expect(!redraw);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("vi  \n    ", dump); // alt 내용 보존(무동작)
}

test "clearScreen without prompt classification clears above the cursor and keeps the current line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    // CUP로 결정적으로 배치한다(\n의 CR 동반 여부에 의존하지 않게). 셸 통합 없음 → semantic_state=.unknown.
    try core.write("\x1b[1;1Haaa"); // row0 = "aaa "
    try core.write("\x1b[2;1Hbbb"); // row1 = "bbb "
    try core.write("\x1b[3;1Hccc"); // row2 = "ccc ", 커서 (2,3)
    const redraw = core.clearScreen();
    try std.testing.expect(!redraw); // 비프롬프트 → form-feed 안 보냄
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("    \n    \nccc ", dump); // 커서 행 위만 비우고 현재 줄 보존
}

test "clearScreen without prompt classification at row 0 keeps the whole screen (only scrollback wiped)" {
    // 경계: 비프롬프트 + 커서가 0행이면 '커서 위 행'이 없으므로 화면 셀을 하나도 안 지우고 보존한다(스크롤백만 비움).
    // 회귀 가드 — 미래에 row==0 분기가 last_print/화면을 잘못 건드리면 잡는다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[1;1Haaa"); // row0 = "aaa ", 커서 (0,3)
    const redraw = core.clearScreen();
    try std.testing.expect(!redraw); // 비프롬프트 → form-feed 안 보냄
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("aaa \n    ", dump); // 현재 줄(0행) 그대로 보존
}

test "escape sequence split across writes is parsed as one sequence" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // PTY reads can split a sequence; parser state must persist across write().
    try core.write("\x1b[3");
    try core.write("1mX");

    const cell = core.screen.cells[core.index(0, 0)];
    try std.testing.expectEqual(@as(u21, 'X'), cell.codepoint);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, cell.style.foreground);
}

test "OSC sequence is consumed and does not print" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();

    // OSC 0 sets the window title, terminated by BEL; the title text must not show.
    try core.write("\x1b]0;title\x07hi");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi      ", dump);
    // ...but it IS captured as the window title (consumed != discarded).
    try std.testing.expectEqualStrings("title", core.windowTitle());
}

// 창 제목은 xterm OSC 0/2(아이콘+제목 / 제목)로 앱이 지정하거나, 없으면 OSC 7 cwd의 basename으로
// 폴백한다 — 탭/창 제목줄이 읽는 단일 계약이라 우선순위(제목 > cwd basename > 빈값) 로직이 Zig에
// 있어야 한다(native 최소). OSC 1(아이콘만)은 창 제목과 무관하므로 무시돼야 한다.
test "window title: OSC 2 sets it, OSC 1 ignored, empty clears to cwd basename" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try std.testing.expectEqualStrings("", core.windowTitle()); // 아무것도 없으면 빈값
    try std.testing.expectEqual(@as(u32, 0), core.title_generation.load(.monotonic)); // 초기 0(P4-1)

    // cwd만 있으면 basename으로 폴백. windowTitle 결과가 바뀌므로 title_generation +1.
    const g0 = core.title_generation.load(.monotonic);
    try core.write("\x1b]7;file://h/Users/me/proj\x07");
    try std.testing.expectEqualStrings("proj", core.windowTitle());
    try std.testing.expect(core.title_generation.load(.monotonic) > g0);

    // OSC 2 제목이 있으면 그게 우선(cwd basename보다). +1.
    const g1 = core.title_generation.load(.monotonic);
    try core.write("\x1b]2;my app\x1b\\");
    try std.testing.expectEqualStrings("my app", core.windowTitle());
    try std.testing.expect(core.title_generation.load(.monotonic) > g1);

    // OSC 1(아이콘만)은 창 제목을 안 바꾼다 → generation 불변(P4-1: 헛 sync 방지).
    const g2 = core.title_generation.load(.monotonic);
    try core.write("\x1b]1;iconname\x07");
    try std.testing.expectEqualStrings("my app", core.windowTitle());
    try std.testing.expectEqual(g2, core.title_generation.load(.monotonic));

    // 빈 OSC 2는 제목 해제 → 다시 cwd basename 폴백. +1.
    try core.write("\x1b]2;\x07");
    try std.testing.expectEqualStrings("proj", core.windowTitle());
    try std.testing.expect(core.title_generation.load(.monotonic) > g2);

    // RIS는 제목과 cwd를 모두 공장 초기화 → 빈값. +1.
    const g3 = core.title_generation.load(.monotonic);
    try core.write("\x1bc");
    try std.testing.expectEqualStrings("", core.windowTitle());
    try std.testing.expect(core.title_generation.load(.monotonic) > g3);
}

// OSC 7(VTE 사실상 표준)은 셸이 cwd를 보고하는 채널이다 — 터미널은 PTY 너머라 cwd를 모르므로
// 창 제목/새 탭 cwd가 이걸 읽는다. 셸 통합과 platform layer 사이의 단일 계약이라, 형식 파싱과
// percent-decoding이 정확해야 한다. ST(ESC \)·BEL 어느 종결자로 와도 같게 처리돼야 한다.
test "OSC 7 reports cwd: file://host/path is parsed into (host, path), text not printed" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b]7;file://myhost/Users/me/proj\x1b\\hi");

    try std.testing.expectEqualStrings("/Users/me/proj", core.currentCwd());
    try std.testing.expectEqualStrings("myhost", core.currentCwdHost()); // authority 보존(원격 판정의 근거)
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi      ", dump); // OSC 본문은 그리드에 안 보인다
}

// host와 path는 **한 쌍**이다. 한쪽만 갱신되면 새 경로에 옛 host가 붙어 로컬 경로가 원격으로(또는 그 반대로)
// 표시되고, 그 판정에 매인 cwd 상속·경로 resolve까지 함께 틀어진다. 쌍이 늘 함께 움직이는지 고정한다.
test "OSC 7 keeps host and path paired across updates, RIS, and empty authority" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b]7;file://box/a\x07");
    try std.testing.expectEqualStrings("box", core.currentCwdHost());

    // 빈 authority(file:///path = VTE 규약 localhost)는 host를 **지운다** — 옛 host가 남으면 로컬 보고가
    // 계속 원격으로 보인다.
    try core.write("\x1b]7;file:///b\x07");
    try std.testing.expectEqualStrings("/b", core.currentCwd());
    try std.testing.expectEqualStrings("", core.currentCwdHost());

    // 다시 원격 → 로컬로 돌아올 때도 마찬가지.
    try core.write("\x1b]7;file://other/c\x07");
    try std.testing.expectEqualStrings("other", core.currentCwdHost());

    // 형식이 깨진 보고는 이전 쌍을 통째로 유지한다(부분 갱신 금지).
    try core.write("\x1b]7;file://hostonly\x07"); // path 없음
    try std.testing.expectEqualStrings("/c", core.currentCwd());
    try std.testing.expectEqualStrings("other", core.currentCwdHost());

    // **경로가 같고 host만 바뀌는 전이**에서도 generation이 오른다. 이 값이 observation refresh의 게이트라,
    // 안 오르면 폴더줄이 옛 host를 계속 그리고 cwd 상속·링크 스코프도 옛 판정에 머문다(적대적 검증에서 발견).
    try core.write("\x1b]7;file://host-a/same\x07");
    const gen_before = core.title_generation.load(.monotonic);
    try core.write("\x1b]7;file://host-b/same\x07"); // 경로 동일, host만 교체
    try std.testing.expectEqualStrings("host-b", core.currentCwdHost());
    try std.testing.expect(core.title_generation.load(.monotonic) > gen_before);
    // 값이 완전히 같은 재보고(셸이 매 프롬프트 보내는 것)는 여전히 bump하지 않는다 — 헛 sync 방지 계약 유지.
    const gen_same = core.title_generation.load(.monotonic);
    try core.write("\x1b]7;file://host-b/same\x07");
    try std.testing.expectEqual(gen_same, core.title_generation.load(.monotonic));

    // RIS는 cwd와 host를 함께 공장 초기화한다.
    try core.write("\x1bc");
    try std.testing.expectEqualStrings("", core.currentCwd());
    try std.testing.expectEqualStrings("", core.currentCwdHost());
}

// cwd와 host는 한 쌍이다. "path는 새 값인데 host는 옛 값"(또는 빈 값)이 되면 로컬 경로에 원격 host가 붙거나 그
// 반대가 되어, 표시·cwd 상속·링크 스코프가 **전부 반대로** 판정된다. 갱신 도중 어느 할당이 실패해도 쌍이 깨지지
// 않는지 실패 지점을 하나씩 옮겨 가며 확인한다.
//
// `checkAllAllocationFailures`는 쓸 수 없다 — 그 헬퍼는 "할당이 실패했으면 함수도 OutOfMemory를 반환해야 한다"고
// 요구하는데, `dispatchCwd`는 **의도적으로 OOM을 삼키고 이전 값을 유지**하는 계약이라 곧바로
// `SwallowedOutOfMemoryError`가 된다(실제로 그렇게 실패했다). 그래서 실패 인덱스를 직접 돌린다.
test "OSC 7 never leaves a half-updated (host, path) pair under allocation failure" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b]7;file://host-a/a\x07"); // 정상 할당으로 첫 쌍을 세운다

    // dispatchCwd 한 번의 할당은 percent-decode(ArrayList grow)와 host dupe 몇 회뿐이라 상한을 넉넉히 덮는다.
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        core.allocator = failing.allocator();
        core.write("\x1b]7;file://host-b/b\x07") catch {};
        core.allocator = std.testing.allocator; // 이후 free는 같은 backing이라 안전하다

        const cwd = core.currentCwd();
        const host = core.currentCwdHost();
        const first = std.mem.eql(u8, cwd, "/a") and std.mem.eql(u8, host, "host-a");
        const second = std.mem.eql(u8, cwd, "/b") and std.mem.eql(u8, host, "host-b");
        if (!(first or second)) {
            std.debug.print("\n[half-updated pair @fail_index={d}] cwd=\"{s}\" host=\"{s}\"\n", .{ fail_index, cwd, host });
            return error.TestUnexpectedResult;
        }
    }
}

// authority는 셸이 `${HOST}`로 채우지만 그 값을 터미널이 통제할 수는 없다(사용자 설정·컨테이너·악의적 출력).
// 이상한 authority가 와도 파싱이 무너지거나 로컬/원격 판정이 뒤집히지 않아야 한다 — 뒤집히면 원격 경로가 로컬
// spawn·링크로 새거나(위험) 로컬 세션의 cwd 상속이 통째로 꺼진다(기능 상실).
test "OSC 7 tolerates unusual authorities without breaking the pair or the local/remote verdict" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();

    // authority만 있고 path가 없으면 형식 위반 → 이전 값 유지(여기선 아직 없음).
    try core.write("\x1b]7;file://onlyhost\x07");
    try std.testing.expectEqualStrings("", core.currentCwd());
    try std.testing.expectEqualStrings("", core.currentCwdHost());

    // path가 루트 하나뿐이어도 정상 보고다.
    try core.write("\x1b]7;file:///\x07");
    try std.testing.expectEqualStrings("/", core.currentCwd());
    try std.testing.expectEqualStrings("", core.currentCwdHost());
    try std.testing.expect(TerminalCore.hostIsLocal(core.currentCwdHost(), "box")); // 빈 authority = 로컬

    // IPv6 리터럴은 대괄호째 authority가 된다(첫 '/' 앞이라 파싱이 갈리지 않는다). 로컬 이름과 다르므로 원격으로
    // 본다 — `[::1]`이 실제로는 로컬이지만, 오판 방향이 "원격으로 봄"이라 안전한 쪽이다(§9.2 보수적 기본).
    try core.write("\x1b]7;file://[::1]/srv\x07");
    try std.testing.expectEqualStrings("/srv", core.currentCwd());
    try std.testing.expectEqualStrings("[::1]", core.currentCwdHost());
    try std.testing.expect(!TerminalCore.hostIsLocal(core.currentCwdHost(), "box"));

    // authority의 percent-escape는 **디코드하지 않는다**(hostname에 인코딩이 오지 않고, 디코드하면 `%`가 든 이름이
    // 다른 호스트로 바뀐다). 값이 그대로 보존되는지 고정.
    try core.write("\x1b]7;file://my%20host/p\x07");
    try std.testing.expectEqualStrings("my%20host", core.currentCwdHost());

    // 경로가 `//`로 시작해도 authority 경계는 첫 '/'라 host가 먹히지 않는다.
    try core.write("\x1b]7;file://h//double\x07");
    try std.testing.expectEqualStrings("//double", core.currentCwd());
    try std.testing.expectEqualStrings("h", core.currentCwdHost());

    // 매우 긴 authority도 쌍을 유지한다(표시 측 말줄임이 폭을 책임진다).
    const long_host = "a" ** 300;
    try core.write("\x1b]7;file://" ++ long_host ++ "/deep\x07");
    try std.testing.expectEqualStrings("/deep", core.currentCwd());
    try std.testing.expectEqual(@as(usize, 300), core.currentCwdHost().len);
}

// ── OSC 9;9 (ConEmu "set working directory") ──────────────────────────────────────────────────
// Windows 네이티브 셸의 cwd 보고는 OSC 7이 아니라 이것이다(docs/windows-platform.md §3.2). OSC 7과 달리
// **authority가 없어** 경로만 온다. 그래서 이 경로는 host를 만들지도 지우지도 않는다(같은 문서 §3.2a의 C).

test "OSC 9;9 sets cwd from a native path and does not print it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();

    // Microsoft가 안내하는 `PROMPT $e]9;9;$P$e\` 형식(따옴표 없음) — 실캡처 바이트와 같은 모양.
    try core.write("\x1b]9;9;C:\\Users\\me\\proj\x1b\\hi");

    try std.testing.expectEqualStrings("C:\\Users\\me\\proj", core.currentCwd());
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi      ", dump);
}

// ConEmu 원본 스펙은 경로를 **따옴표로 감싼다**(`ESC ] 9 ; 9 ; "cwd" ST`). Microsoft가 안내하는 `PROMPT`는
// 감싸지 않는다. 둘 다 실제로 나오는 바이트라(실캡처로 확인) 파서가 양쪽을 받는다. Windows 파일명에 `"`가
// 올 수 없으므로 양끝 따옴표 제거는 모호하지 않다.
test "OSC 9;9 accepts both the quoted ConEmu form and the unquoted Microsoft form" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b]9;9;\"C:\\quoted path\"\x07");
    try std.testing.expectEqualStrings("C:\\quoted path", core.currentCwd());

    try core.write("\x1b]9;9;C:\\plain\x07");
    try std.testing.expectEqualStrings("C:\\plain", core.currentCwd());

    // 여는 따옴표만 있는 비정상 입력은 그대로 둔다(양끝이 짝일 때만 벗긴다).
    try core.write("\x1b]9;9;\"C:\\half\x07");
    try std.testing.expectEqualStrings("\"C:\\half", core.currentCwd());
}

// **핵심 계약**: 9;9은 authority를 나르지 않으므로 host를 건드리지 않는다. 지우면 원격 세션이 로컬로
// 뒤집히고(원격 경로를 로컬 파일시스템에 대고 해석 → 남의 저장소에 stage/discard), 만들어 내면 없는
// 근거로 원격을 주장하게 된다. docs/windows-platform.md §3.2a.
test "OSC 9;9 leaves the cwd host untouched — it carries no authority" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // 원격 host가 선 상태에서 9;9이 오면 **원격을 유지**한다.
    try core.write("\x1b]7;file://buildbox/srv/app\x07");
    try std.testing.expectEqualStrings("buildbox", core.currentCwdHost());
    try core.write("\x1b]9;9;C:\\after\x07");
    try std.testing.expectEqualStrings("C:\\after", core.currentCwd());
    try std.testing.expectEqualStrings("buildbox", core.currentCwdHost()); // 지우지 않는다

    // 로컬(빈 host)에서 9;9이 와도 host를 만들지 않는다.
    try core.write("\x1b]7;file:///local\x07");
    try std.testing.expectEqualStrings("", core.currentCwdHost());
    try core.write("\x1b]9;9;C:\\local2\x07");
    try std.testing.expectEqualStrings("C:\\local2", core.currentCwd());
    try std.testing.expectEqualStrings("", core.currentCwdHost()); // 만들지도 않는다
}

// title_generation은 창 제목 재sync만이 아니라 **runtime observation refresh의 게이트**다. 빠뜨리면 경로가
// 바뀌어도 관측이 안 돌아 폴더줄·cwd 상속·링크 스코프가 옛 판정에 머문다(같은 결함이 host 축에서 실제로
// 발생한 적 있다 — osc.zig `dispatchCwd` 주석). 값이 그대로면 올리지 않는다(헛 sync 방지).
test "OSC 9;9 bumps title generation only when the path actually changes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b]9;9;C:\\a\x07");
    const after_first = core.title_generation.load(.monotonic);

    try core.write("\x1b]9;9;C:\\a\x07"); // 같은 경로 재보고(매 프롬프트) — 올리지 않는다
    try std.testing.expectEqual(after_first, core.title_generation.load(.monotonic));

    try core.write("\x1b]9;9;C:\\b\x07"); // 실제로 바뀌면 올린다
    try std.testing.expect(core.title_generation.load(.monotonic) > after_first);
}

// 빈 경로·OOM은 **기존 cwd를 유지**한다 — 부분 갱신으로 이전 값을 잃지 않는다(OSC 7과 같은 결).
test "OSC 9;9 with an empty path keeps the previous cwd" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b]9;9;C:\\keep\x07");
    try core.write("\x1b]9;9;\x07");
    try std.testing.expectEqualStrings("C:\\keep", core.currentCwd());
    try core.write("\x1b]9;9;\"\"\x07"); // 따옴표만 있는 빈 경로도 같다
    try std.testing.expectEqualStrings("C:\\keep", core.currentCwd());
}

// 회귀: 같은 OSC 9를 쓰는 이웃들이 그대로여야 한다. `9;4`(ConEmu progress)는 agent_progress로,
// 숫자 서브커맨드가 아닌 본문은 iTerm2 알림으로 계속 간다.
test "OSC 9;9 does not disturb OSC 9;4 progress or plain OSC 9 notifications" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b]9;4;1;40\x07");
    try std.testing.expectEqualStrings("4;1;40", core.agentProgress());

    try core.write("\x1b]9;빌드 완료\x07");
    try std.testing.expect(core.pendingNotification() != null);
    core.clearNotification();

    try core.write("\x1b]9;9;C:\\x\x07"); // cwd는 알림을 만들지 않는다
    try std.testing.expect(core.pendingNotification() == null);
    try std.testing.expectEqualStrings("C:\\x", core.currentCwd());
}

// 로컬 판정은 순수 함수다 — 이 판정 하나가 폴더줄 표시·cwd 상속·경로 resolve를 모두 가른다.
// 특히 짧은 이름 대 FQDN 비대칭은 실제로 흔해서(셸은 `${HOST}`에 짧은 이름을 싣고 로컬은 `.local`이
// 붙는다), 그대로 비교하면 **자기 자신을 원격으로 오인**해 로컬 세션의 cwd 상속이 조용히 꺼진다.
test "hostIsLocal: empty/localhost/self are local, short-vs-FQDN matches, others are remote" {
    try std.testing.expect(TerminalCore.hostIsLocal("", "box.local")); // file:///path
    try std.testing.expect(TerminalCore.hostIsLocal("localhost", "box.local"));
    try std.testing.expect(TerminalCore.hostIsLocal("LocalHost", "box.local")); // 대소문자 무시
    try std.testing.expect(TerminalCore.hostIsLocal("box.local", "box.local"));
    try std.testing.expect(TerminalCore.hostIsLocal("BOX.local", "box.local"));
    try std.testing.expect(TerminalCore.hostIsLocal("box", "box.local")); // 짧은 이름 대 FQDN
    try std.testing.expect(TerminalCore.hostIsLocal("box.local", "box")); // 반대 방향
    try std.testing.expect(!TerminalCore.hostIsLocal("server", "box.local"));
    try std.testing.expect(!TerminalCore.hostIsLocal("boxy", "box.local")); // prefix 일치는 다른 호스트
    // **양쪽 다 FQDN이면 첫 라벨이 같아도 다른 호스트다.** 첫 라벨만 비교하면 사내망의 동명 서버가 로컬로
    // 판정돼 원격 경로가 로컬 spawn·경로 resolve로 새어 나간다(적대적 검증에서 발견).
    try std.testing.expect(!TerminalCore.hostIsLocal("box.corp.com", "box.home.net"));
    try std.testing.expect(!TerminalCore.hostIsLocal("box.corp.com", "box.local"));
    try std.testing.expect(TerminalCore.hostIsLocal("box.corp.com", "box.corp.com")); // 전체 일치는 여전히 로컬
    // 로컬 이름을 못 얻으면 보수적으로 원격 — 없는 경로로 spawn하는 쪽이 host 접두가 붙는 쪽보다 나쁘다.
    try std.testing.expect(!TerminalCore.hostIsLocal("box", ""));
    try std.testing.expect(TerminalCore.hostIsLocal("", "")); // 단 빈 authority는 여전히 로컬
}

// 위 테스트의 `!hostIsLocal("box.corp.com", "box.local")`은 **같은 머신의 두 이름**일 수도 있다 — macOS는 DHCP
// 도메인·Wi-Fi 전환·슬립 복귀로 hostname의 접미를 바꾸므로, 셸이 시작할 때 본 이름과 앱이 시작할 때 본 이름이
// 갈릴 수 있다. 그 단정을 완화하면 사내망 동명 서버가 로컬로 새므로(위 주석) 판정은 그대로 두고, **로컬 보고자가
// 추측할 거리를 주지 않는 쪽**으로 막았다: maru의 로컬 셸 통합은 authority를 비워 보낸다(shell_integration.zig).
// 이 테스트가 그 계약의 반대편 — "빈 authority는 로컬 이름이 어떤 상태든 로컬" — 을 고정한다.
test "hostIsLocal: 빈 authority는 로컬 이름의 상태와 무관하게 로컬이다(로컬 셸 통합의 계약)" {
    try std.testing.expect(TerminalCore.hostIsLocal("", "")); // 이름을 못 얻은 순간
    try std.testing.expect(TerminalCore.hostIsLocal("", "localhost")); // 네트워크 구성 전 임시 이름
    try std.testing.expect(TerminalCore.hostIsLocal("", "box.lan")); // DHCP가 준 도메인
    try std.testing.expect(TerminalCore.hostIsLocal("", "box.local")); // mDNS 이름
    // 대조군: authority가 실려 있으면 판정은 예전 그대로다(원격 rc의 스니펫은 계속 ${HOST}를 싣는다 — §9.5).
    try std.testing.expect(!TerminalCore.hostIsLocal("build-box", "box.local"));
}

test "OSC 7 percent-decodes the path (spaces, UTF-8 bytes round-trip)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // BEL 종결자 + %20(공백) + percent-인코딩된 UTF-8('가'=EA B0 80) + raw로 통과하는 ASCII.
    try core.write("\x1b]7;file://localhost/a%20b/%EA%B0%80\x07");
    try std.testing.expectEqualStrings("/a b/\xea\xb0\x80", core.currentCwd());

    // 잘린 %escape는 관대하게 '%'를 리터럴로 둔다(한 글자 깨졌다고 전체를 버리지 않음).
    try core.write("\x1b]7;file://localhost/x%2\x07");
    try std.testing.expectEqualStrings("/x%2", core.currentCwd());
}

test "OSC 7 keeps prior cwd on malformed input, clears on RIS" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b]7;file://h/good\x07");
    try std.testing.expectEqualStrings("/good", core.currentCwd());

    // file 스킴 아님 / path 없음(authority만) → 기존 cwd 유지.
    try core.write("\x1b]7;http://h/other\x07");
    try core.write("\x1b]7;file://hostonly\x07");
    try std.testing.expectEqualStrings("/good", core.currentCwd());

    // RIS(ESC c) 하드 리셋 → cwd도 공장 초기화(빈 값).
    try core.write("\x1bc");
    try std.testing.expectEqualStrings("", core.currentCwd());
}

test "private CSI sequences are consumed without printing" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // Cursor visibility toggles (DECTCEM) must not leak as text.
    try core.write("\x1b[?25lhi\x1b[?25h");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi    ", dump);
}

test "resize preserves overlapping content when growing" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    try core.write("hello");
    try core.resize(8, 1);

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hello   ", dump);
}

test "resize leaves the cursor's line verbatim when shrinking (shell redraws it)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    try core.write("hello");
    try core.resize(3, 1);

    // "hello"는 커서가 있는 줄이므로 reflow하지 않고 그대로 둔다(xterm.js 방식 — 셸이 SIGWINCH로
    // 다시 그린다). 새 폭(3)으로 clip돼 "hel"이 남고, 커서는 폭 안으로 clamp된다. 스크롤백 push 없음.
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hel", dump);
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col); // col 4 -> clamp 2
}

test "resize preserves content across multiple rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 2 });
    defer core.deinit();

    try core.write("ab");
    try core.write("\x1b[2;1Hcd");
    try core.resize(4, 3);

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("ab  \ncd  \n    ", dump);
}

test "resize clamps the cursor into the new bounds instead of resetting it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 3 });
    defer core.deinit();

    try core.write("\x1b[3;5H");
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.screen.cursor.col);

    try core.resize(2, 2);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.col);
}

test "eraseInDisplay merges dirty instead of dropping earlier-dirtied rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 4 });
    defer core.deinit();
    core.clearDirty();

    // Print on the bottom row, then move the cursor up and erase start-to-cursor (mode 1).
    try core.write("\x1b[4;1HX");
    try core.write("\x1b[2;1H\x1b[1J");

    // The bottom row (3) where X was printed must remain dirty — not be dropped by the erase.
    const dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), dirty.start_row);
    try std.testing.expect(dirty.end_row >= 3);
}

test "ESC inside a CSI restarts as a new escape instead of leaking as text" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // CSI opened by '[', then ESC cancels it and a fresh CSI sets red and prints X.
    try core.write("\x1b[\x1b[31mX");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("X     ", dump);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.screen.cells[core.index(0, 0)].style.foreground);
}

test "C0 control inside a CSI is executed and the CSI still completes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // Backspace (0x08) embedded mid-CSI must not abort it: the SGR red still applies, X prints red.
    try core.write("\x1b[31\x08mX");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("X   ", dump);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.screen.cells[core.index(0, 0)].style.foreground);
}

test "CSI with more than 16 parameters discards the overflow instead of corrupting param 15" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();

    // 16 zero params fill the buffer; the 17th param (1 = bold) is past the cap and must be dropped,
    // not folded into params[15] (which the old guard did, applying spurious bold).
    try core.write("\x1b[0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;1mA");
    try std.testing.expect(!core.screen.cells[core.index(0, 0)].style.bold);
}

test "resize clears a wide glyph whose continuation is clipped at the new right edge" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("A한");
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[core.index(0, 1)].width);

    // Shrink so the wide glyph's continuation (col 2) is clipped; the dangling base must be cleared.
    try core.resize(2, 1);
    try std.testing.expect(core.screen.cells[core.index(0, 1)].width != 2);
}

test "erasing the continuation half of a wide glyph clears its dangling base" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("한X");
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[core.index(0, 0)].width);

    // Cursor onto the continuation (col 1), erase cursor-to-end: the base at col 0 is now dangling.
    try core.write("\x1b[2G\x1b[K");
    try std.testing.expect(core.screen.cells[core.index(0, 0)].width != 2);
}

test "eraseInLine ends the grapheme run so a later combining mark is dropped" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("A");
    try core.write("\x1b[1G\x1b[K");
    try core.write("\u{0301}");

    try expectCluster(&core, core.screen.cells[core.index(0, 0)].grapheme_id, &.{});
}

test "SGR colon sub-parameter direct color (38:2:cs:r:g:b) reads RGB past the colorspace slot" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // ITU colon form with an empty colorspace slot: '::' inserts an extra component before r,g,b.
    // The parser must skip the colorspace and read 10/20/30 — not 0/10/20.
    try core.write("\x1b[38:2::10:20:30mA");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.screen.cells[core.index(0, 0)].style.foreground,
    );

    // Colon 256-color form: n sits at the same offset as the semicolon form.
    try core.write("\x1b[38:5:200mB");
    try std.testing.expectEqual(types.Color{ .indexed = 200 }, core.screen.cells[core.index(0, 1)].style.foreground);

    // Semicolon form must stay correct (no colorspace component).
    try core.write("\x1b[48;2;1;2;3mC");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        core.screen.cells[core.index(0, 2)].style.background,
    );
}

test "printable characters auto-wrap to the next line at the right edge (DECAWM)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABCDE"); // ABCD fills row 0; E wraps to row 1
    try std.testing.expectEqual(@as(u21, 'A'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), core.screen.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), core.screen.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.col);
}

test "a line filled exactly then CR/LF does not insert a blank wrapped line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    // ABCD가 row 0을 정확히 채워 pending_wrap이 서지만, \r\n이 그걸 무효화해 X는 row 1에 온다
    // (deferred wrap이 아니면 \n이 한 줄 더 내려가 X가 row 2에 떨어진다).
    try core.write("ABCD\r\nX");
    try std.testing.expectEqual(@as(u21, 'D'), core.screen.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), core.screen.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
}

test "overflow fill wraps so a following prompt lands on a new line, not over the content" {
    // 사용자 실제 시나리오: 개행 없이 끝난 출력(파란 배경) 뒤에 zsh PROMPT_SP가 줄 끝을 넘겨
    // 공백을 채워 다음 줄로 wrap시키고 \r + 프롬프트를 그린다. autowrap이 있어야 프롬프트가
    // wrap된 줄(row 1)에 떨어지고 파란 줄(row 0)을 덮지 않는다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[44mBLUE\x1b[0m"); // BLUE(파란 배경) at row 0, cursor (0,4)
    try core.write("            "); // 12 spaces: 4 fill row 0, wrap, 8 fill row 1
    try core.write("\rPROMPT"); // \r clears pending_wrap; PROMPT at row 1
    try std.testing.expectEqual(@as(u21, 'B'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(types.Color{ .indexed = 4 }, core.screen.cells[core.index(0, 0)].style.background);
    try std.testing.expectEqual(@as(u21, 'P'), core.screen.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
}

test "cursor positioning cancels a pending wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABCD"); // fills row 0, pending_wrap set
    try core.write("\x1b[1;1H"); // CUP to (0,0) cancels pending_wrap
    try core.write("X"); // X overwrites (0,0), does NOT wrap to row 1
    try std.testing.expectEqual(@as(u21, 'X'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.col);
}

test "a wide glyph with one column left wraps whole to the next line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABC"); // A,B,C at cols 0,1,2; cursor (0,3) one column left
    try core.write("한"); // wide(2): doesn't fit in 1 col -> wraps to row 1
    try std.testing.expectEqual(@as(u21, '한'), core.screen.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[core.index(1, 0)].width);
    try std.testing.expect(core.screen.cells[core.index(1, 1)].continuation);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
}

test "the grid is clamped to at least 2 columns so wide glyphs never write out of bounds" {
    // 1칸 grid는 wide glyph(2칸) continuation에서 col+1 OOB를 부른다. init/resize가 최소 2칸으로
    // 맞춰 그 degenerate 입력을 원천 차단하므로, wide glyph는 degrade 없이 통째로 들어간다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 1, .rows = 1 });
    defer core.deinit();
    try std.testing.expectEqual(@as(u16, 2), core.size.cols);
    try std.testing.expectEqual(@as(u16, 1), core.size.rows);
    try core.write("한"); // wide(2)가 OOB/degrade 없이 2칸으로 들어간다
    try std.testing.expectEqual(@as(u21, '한'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[core.index(0, 0)].width);
    try std.testing.expect(core.screen.cells[core.index(0, 1)].continuation);
    // resize도 같은 최소 크기를 보장한다.
    try core.resize(1, 4);
    try std.testing.expectEqual(@as(u16, 2), core.size.cols);
}

test "a bottom-row line feed clears pending wrap so the next char does not double-scroll" {
    // 바닥 행이 꽉 차(pending_wrap) bare LF가 오면 scroll이 일어나는데, pending_wrap이 안 지워지면
    // 다음 printable 글자가 또 scroll해 직전 줄을 잃었다(이중 스크롤). lineFeed가 pending_wrap을
    // 끄므로 ABCD가 row 0에 보존되고 X가 row 1에 와야 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\r\nABCD"); // row 1을 채움 -> pending_wrap at (1,3)
    try core.write("\n"); // 바닥 bare LF -> scrollRegionUp 한 번(ABCD -> row 0), 컬럼은 보존
    try core.write("X"); // pending_wrap stale면 또 scroll돼 ABCD 유실. 고쳐지면 한 번만 scroll.
    // 핵심: ABCD가 row 0에 보존된다(버그면 두 번 scroll돼 row 0이 빈칸). bare LF는 컬럼을
    // 보존하므로 X는 (1,3)에 온다.
    try std.testing.expectEqual(@as(u21, 'A'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), core.screen.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), core.screen.cells[core.index(1, 3)].codepoint);
}

test "autowrap at the scroll-bottom keeps the soft-wrap flag (reflow가 논리 줄을 안 쪼갠다)" {
    // putCell이 soft-wrap 플래그를 lineFeed '전'에 세우면, 바닥에서 wrap+scroll할 때 scrollRangeUp의
    // 경계 fixup이 그 플래그를 지운다 → resize reflow가 autowrap된 한 논리 줄을 둘로 쪼갠다. 플래그를
    // lineFeed '후'에 세워(promoteLastToEmojiWidth와 같은 패턴) scroll에도 살아남게 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcd"); // row0 가득 -> pending_wrap
    try core.write("efgh"); // 'e'가 row1로 wrap, row1 가득 -> pending_wrap at scroll_bottom
    try core.write("i"); // autowrap + scroll: efgh -> row0, i -> row1 col0
    // efgh(row0)는 i 줄(row1)로 이어지는 soft-wrap이다 — 플래그가 scroll fixup에 안 지워져야 한다.
    try std.testing.expect(core.screen.wrapped[0]);
    // i 하나만 있는 마지막 줄은 아직 어디로도 안 이어진다(회귀: 새로 쓴 행은 wrap 리셋).
    try std.testing.expect(!core.screen.wrapped[1]);
}

test "SGR colon direct color without a colorspace component (38:2:r:g:b) sets RGB" {
    // ITU colon form은 colorspace 슬롯이 생략될 수 있다(38:2:r:g:b, 5컴포넌트). 이전엔 colorspace가
    // 항상 있다고 가정해 색을 통째로 버렸다. r,g,b는 colon 컴포넌트의 마지막 3개로 읽어야 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[38:2:10:20:30mA");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.screen.cells[core.index(0, 0)].style.foreground,
    );
    // 빈 colorspace(38:2::r:g:b)와 colorspace 있는(38:2:1:r:g:b) 6컴포넌트도 여전히 정확.
    try core.write("\x1b[38:2::40:50:60mB");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 40, .g = 50, .b = 60 } },
        core.screen.cells[core.index(0, 1)].style.foreground,
    );
}

test "a tab near the last column does not overflow the tab-stop arithmetic" {
    // cols가 maxInt(u16)까지 허용되므로(거대 창), 마지막 칸 근처 탭에서 (col/8+1)*8이 u16을 넘길 수
    // 있다. 포화 곱셈으로 패닉/OOB 없이 마지막 칸에 멈춰야 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 65535, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[65535G"); // CHA -> 마지막 칸(65534)으로 clamp
    try core.write("\t"); // 패닉하면 안 됨
    try std.testing.expectEqual(@as(u16, 65534), core.screen.cursor.col);
}

test "HT(tab)는 지나는 셀을 덮지 않고 커서만 옮긴다 (xterm/Ghostty)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 1 });
    defer core.deinit();
    try core.write("ABCDEF"); // col0~5
    try core.write("\r\t"); // CR(col0) → HT → 다음 8-탭스톱(col8)
    // ABCDEF가 보존된다 — 예전엔 putCell(' ')로 col0~7을 덮어 글자가 사라졌다.
    try std.testing.expectEqual(@as(u21, 'A'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), core.screen.cells[core.index(0, 2)].codepoint);
    try std.testing.expectEqual(@as(u21, 'F'), core.screen.cells[core.index(0, 5)].codepoint);
    try std.testing.expectEqual(@as(u16, 8), core.screen.cursor.col); // 커서만 탭스톱으로 이동
}

test "backspace cancels a pending wrap so the next char does not wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABCD"); // row 0을 채움 -> pending_wrap at (0,3)
    try core.write("\x08"); // backspace -> (0,2), markCursorMoveDirty가 pending_wrap을 끈다
    try core.write("X"); // (0,2)에 덮어쓰고 wrap하지 않는다
    try std.testing.expectEqual(@as(u21, 'X'), core.screen.cells[core.index(0, 2)].codepoint);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
}

test "SGR colon background direct color (48:2:r:g:b) sets the cell background" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // 전경(38)뿐 아니라 배경(48)도 colon 형식 + colorspace 생략을 처리해야 한다.
    try core.write("\x1b[48:2:10:20:30mA");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.screen.cells[core.index(0, 0)].style.background,
    );
}

test "SGR colon sub-parameter는 직전 주 파라미터에 종속 — 별도 SGR로 새지 않는다 (4:3/4:0)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // 4:3 (curly underline) — underline만 켜지고 italic(SGR 3)은 안 켜진다(예전엔 :3을 italic으로 오인).
    try core.write("\x1b[4:3m");
    try std.testing.expect(core.screen.pen.underline);
    try std.testing.expect(!core.screen.pen.italic);
    // bold 후 4:0 (underline off) — bold는 유지된다(예전엔 :0을 SGR 0=전체 리셋으로 오인해 bold까지 날렸다).
    try core.write("\x1b[0m\x1b[1m\x1b[4:0m");
    try std.testing.expect(core.screen.pen.bold);
    try std.testing.expect(!core.screen.pen.underline);
    // 회귀: sub-param 스킵이 38/48 확장색을 망가뜨리지 않는다(세미콜론·콜론 형식 모두).
    try core.write("\x1b[0m\x1b[38;2;10;20;30m");
    try std.testing.expectEqual(types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, core.screen.pen.foreground);
    try core.write("\x1b[38:2:40:50:60m");
    try std.testing.expectEqual(types.Color{ .rgb = .{ .r = 40, .g = 50, .b = 60 } }, core.screen.pen.foreground);
}

test "printable text wraps across multiple rows filling each line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 3 });
    defer core.deinit();
    try core.write("ABCDEF"); // AB / CD / EF
    try std.testing.expectEqual(@as(u21, 'A'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), core.screen.cells[core.index(0, 1)].codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), core.screen.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), core.screen.cells[core.index(1, 1)].codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), core.screen.cells[core.index(2, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'F'), core.screen.cells[core.index(2, 1)].codepoint);
}

test "a wide glyph filling the last two columns sets pending wrap and the next char wraps" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("AB"); // A(0,0) B(0,1), 커서 (0,2)
    try core.write("한"); // 마지막 두 칸(2,3)을 채움 -> 커서 (0,3) pending_wrap
    try core.write("X"); // 다음 줄로 wrap
    try std.testing.expectEqual(@as(u21, '한'), core.screen.cells[core.index(0, 2)].codepoint);
    try std.testing.expect(core.screen.cells[core.index(0, 3)].continuation);
    try std.testing.expectEqual(@as(u21, 'X'), core.screen.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
}

test "clampGridSize enforces a minimum of 2 columns and 1 row" {
    try std.testing.expectEqual(types.Size{ .cols = 2, .rows = 5 }, clampGridSize(.{ .cols = 1, .rows = 5 }));
    try std.testing.expectEqual(types.Size{ .cols = 2, .rows = 1 }, clampGridSize(.{ .cols = 0, .rows = 0 }));
    try std.testing.expectEqual(types.Size{ .cols = 80, .rows = 24 }, clampGridSize(.{ .cols = 80, .rows = 24 }));
}

test "tab advances to the next 8-column stop mid-line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 16, .rows = 1 });
    defer core.deinit();
    // 엣지(마지막 칸)가 아니라 일반 전진: 'a'(col 1) 뒤 tab은 다음 8-stop(col 8)으로 간다.
    try core.write("a\t");
    try std.testing.expectEqual(@as(u16, 8), core.screen.cursor.col);
}

test "scrollback keeps rows that scroll off the top" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // rows=2. 각 줄이 바닥에서 scroll될 때 맨 윗줄이 스크롤백으로 들어간다.
    try core.write("a\r\nb\r\nc\r\nd");
    // 'a' 줄과 'b' 줄이 밀려났다. 화면엔 c/d가 남는다.
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try std.testing.expectEqual(@as(u21, 'a'), core.scrollbackRow(0).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.scrollbackRow(1).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.screen.cells[core.index(1, 0)].codepoint);
}

test "scrollback ring drops the oldest rows past max_scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.screen.sb.cap = 2; // 첫 scroll 전에 cap을 작게 둔다(lazy 할당이 이 값을 쓴다).
    // a,b,c가 차례로 밀려난다(d/e는 화면에 남음). cap=2라 가장 최근 2개(b,c)만 남는다.
    try core.write("a\r\nb\r\nc\r\nd\r\ne");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try std.testing.expectEqual(@as(u21, 'b'), core.scrollbackRow(0).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.scrollbackRow(1).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), core.screen.cells[core.index(1, 0)].codepoint);
}

test "scrollback disabled when max_scrollback is zero" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.screen.sb.cap = 0;
    try core.write("a\r\nb\r\nc\r\nd");
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
}

test "renderSnapshot은 스크롤 중에도 스크롤바 근거(scrollback_len·view_offset)를 싣는다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백=[a,b], 활성=[c,d]

    // 바닥: 두 값이 실린다(이 갈래는 `snapshot()` 을 그대로 쓴다).
    {
        const snap = core.renderSnapshot();
        try std.testing.expectEqual(@as(usize, 2), snap.scrollback_len);
        try std.testing.expectEqual(@as(usize, 0), snap.view_offset);
    }

    // **스크롤 중에도 실려야 한다.** 이 둘이 빠지면 기본값 0이 나가고, 스크롤바 thumb 기하가
    // `sb_count == 0` 으로 null 이 되어 **스크롤하는 순간 스크롤바가 사라진다**(2026-08-30 사용자
    // 보고 — 실측 로그에서 바닥 sb=235 / 스크롤 중 sb=0 으로 갈렸다). 합성 갈래가 자기 return 을
    // 따로 들기 때문에 생긴 누락이라, 바닥만 보는 판정자로는 안 잡힌다.
    core.scrollViewport(1);
    {
        const snap = core.renderSnapshot();
        try std.testing.expectEqual(@as(usize, 1), snap.view_offset);
        try std.testing.expectEqual(@as(usize, 2), snap.scrollback_len);
        try std.testing.expect(snap.viewport_scrolled);
    }

    // 맨 위까지 올려도 마찬가지다(clamp 된 offset 이 그대로 실린다).
    core.scrollViewport(5);
    {
        const snap = core.renderSnapshot();
        try std.testing.expectEqual(@as(usize, 2), snap.view_offset);
        try std.testing.expectEqual(@as(usize, 2), snap.scrollback_len);
    }

    // 바닥으로 돌아오면 다시 0 이다.
    core.scrollToBottom();
    {
        const snap = core.renderSnapshot();
        try std.testing.expectEqual(@as(usize, 0), snap.view_offset);
        try std.testing.expectEqual(@as(usize, 2), snap.scrollback_len);
    }
}

test "scrollViewport reveals scrollback at the top and scrollToBottom returns to active" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백=[a,b], 활성=[c,d]
    // 바닥(0): 활성 화면이 보인다.
    try std.testing.expectEqual(@as(u21, 'c'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.viewportRow(1)[0].codepoint);
    // 1줄 위로: 윗줄에 가장 최근 스크롤백('b'), 아랫줄에 활성 첫 줄('c'). 'd'는 가려진다.
    core.scrollViewport(1);
    try std.testing.expectEqual(@as(usize, 1), core.viewOffset());
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.viewportRow(1)[0].codepoint);
    // 더 위로: 스크롤백 맨 위(a,b). 범위를 넘겨도 sb_count(2)로 clamp.
    core.scrollViewport(5);
    try std.testing.expectEqual(@as(usize, 2), core.viewOffset());
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(1)[0].codepoint);
    // 바닥으로: 다시 활성.
    core.scrollToBottom();
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());
    try std.testing.expectEqual(@as(u21, 'c'), core.viewportRow(0)[0].codepoint);
}

test "scroll-lock keeps the viewport on the same content as new output scrolls in" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc"); // 스크롤백=[a], 활성=[b,c]
    core.scrollViewport(1); // 위로 -> 뷰는 'a','b'
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(1)[0].codepoint);
    // 새 출력이 scroll돼 들어와도(b가 스크롤백으로), 뷰는 같은 'a','b'를 계속 보여준다(scroll-lock).
    try core.write("\r\nd");
    try std.testing.expectEqual(@as(usize, 2), core.viewOffset()); // offset이 함께 올라감
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(1)[0].codepoint);
}

test "renderSnapshot shows active at bottom and composes the viewport (cursor hidden) when scrolled" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백=[a,b], 활성=[c,d], 커서 (1,1)

    // 바닥: 활성 화면 그대로 + 실제 커서(보임).
    const at_bottom = core.renderSnapshot();
    try std.testing.expectEqual(@as(u21, 'c'), at_bottom.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), at_bottom.cells[core.index(1, 0)].codepoint);
    try std.testing.expect(at_bottom.cursor.visible);

    // 맨 위로 스크롤: 뷰포트가 스크롤백(a,b)을 합성, 커서 숨김.
    core.scrollViewport(2);
    const scrolled = core.renderSnapshot();
    try std.testing.expectEqual(@as(u21, 'a'), scrolled.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), scrolled.cells[core.index(1, 0)].codepoint);
    try std.testing.expect(!scrolled.cursor.visible);
    try std.testing.expectEqual(at_bottom.cursor.row, scrolled.cursor.row);
    try std.testing.expectEqual(at_bottom.cursor.col, scrolled.cursor.col);
}

test "wrapped flag: autowrap sets it, rewriting the row clears it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcde"); // abcd가 row0를 채우고 'e'가 autowrap으로 row1로 넘어간다
    try std.testing.expect(core.screen.wrapped[0]); // row0는 soft-wrap
    try std.testing.expect(!core.screen.wrapped[1]); // row1은 아직 wrap 아님
    try core.write("\x1b[1;1Hxy"); // CUP (0,0) 후 짧게 다시 그림 -> wrapped[0] 리셋
    try std.testing.expect(!core.screen.wrapped[0]);
}

test "wrapped flag: a wide glyph pushed whole to the next row marks soft-wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abc한"); // abc가 0..2를 채우고 한(width2)이 col3에 안 들어가 통째로 row1로
    try std.testing.expect(core.screen.wrapped[0]);
}

test "wrapped flag: a hard line-end stays false even with the cursor parked past content" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ab\r"); // 줄을 안 채운 프롬프트 + CR -> 커서 (0,0). row0는 hard 줄끝
    try std.testing.expect(!core.screen.wrapped[0]);
    try core.write("\x1b[1;6H"); // 커서를 내용 너머(col5)로 이동 -> wrap은 안 변함
    try std.testing.expect(!core.screen.wrapped[0]);
}

test "wrapped flag: scrolled-off soft-wrapped row carries its flag into scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcde"); // wrapped[0]=true (abcd가 'e'로 soft-wrap)
    try std.testing.expect(core.screen.wrapped[0]);
    try core.write("\r\nfg"); // 바닥에서 scroll -> abcd(wrapped=true)가 스크롤백으로
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    try std.testing.expect(core.scrollbackRowWrapped(0));
}

test "wrapped flag: erase-in-display mode 2 clears all wrap flags" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcde"); // wrapped[0]=true
    try std.testing.expect(core.screen.wrapped[0]);
    try core.write("\x1b[2J"); // 화면 전체 지움 -> 모든 wrap 플래그 false
    try std.testing.expect(!core.screen.wrapped[0]);
}

test "reflow: the cursor's wrapped line is left unchanged, not re-wrapped" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef"); // 4칸에서 abcd|ef로 soft-wrap, 커서 (1,2)
    try std.testing.expect(core.screen.wrapped[0]);
    try core.resize(8, 3); // 넓혀도 커서 줄이라 합치지 않고 그대로 둔다(셸이 다시 그림)
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("abcd    \nef      \n        ", dump);
    try std.testing.expect(core.screen.wrapped[0]); // verbatim이라 wrap 플래그 유지
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);
}

test "reflow: a non-cursor wrapped line IS reflowed (joined on widen)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\n"); // abcd|ef(행0~1)는 wrap, \r\n으로 커서를 행2로 -> abcdef는 커서 줄 아님
    try std.testing.expect(core.screen.wrapped[0]);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row);
    try core.resize(8, 3); // 커서가 다른 줄이라 abcdef는 reflow돼 한 줄로 합쳐진다
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("abcdef  \n        \n        ", dump);
    try std.testing.expect(!core.screen.wrapped[0]); // 합쳐져 더는 wrap 아님
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row); // 커서(빈 줄)는 한 칸 위로
}

test "reflow: a cursor parked past content on its line clamps (line not reflowed)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();
    try core.write("abc\x1b[1;7H"); // "abc" 후 커서를 (0,6)로(내용 너머) — 커서 줄
    try std.testing.expectEqual(@as(u16, 6), core.screen.cursor.col);
    try core.resize(4, 3); // 커서 줄이라 reflow 안 함. 커서는 새 폭으로 clamp(6 -> 3).
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.col);
    try std.testing.expect(!core.screen.wrapped[0]);
}

test "reflow: a hard prompt line never merges into the next across repeated resizes (no cascade)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("ok\r\n"); // hard 프롬프트 줄
    try core.write("abcdefghij"); // 다음 줄부터 soft-wrap되는 긴 명령
    // 폭을 왕복해도 프롬프트는 항상 hard 줄로 남고 명령과 합쳐지지 않는다.
    try core.resize(4, 4);
    try core.resize(12, 4);
    try core.resize(6, 4);
    try std.testing.expect(!core.screen.wrapped[0]); // 프롬프트 줄은 hard 유지(cascade 없음)
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.startsWith(u8, dump, "ok")); // 첫 줄은 여전히 프롬프트
    try std.testing.expect(std.mem.indexOf(u8, dump, "okabc") == null); // 프롬프트에 명령이 안 붙음
}

test "DSR: CSI 6n replies with the cursor position (CPR, 1-indexed)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();
    try core.write("\x1b[3;5H"); // 커서 (2,4) 0-indexed
    try core.write("\x1b[6n"); // CPR 질의
    try std.testing.expectEqualStrings("\x1b[3;5R", core.pendingResponse());
    core.clearResponse();
    try std.testing.expectEqual(@as(usize, 0), core.pendingResponse().len);
}

test "DSR: CSI 5n replies terminal-OK" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b[5n");
    try std.testing.expectEqualStrings("\x1b[0n", core.pendingResponse());
}

test "DSR: CPR reports the parked-cursor column at the last column" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcd"); // 마지막 칸을 채워 parked(pending_wrap), 커서 (0,3)
    try core.write("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;4R", core.pendingResponse()); // row1 col4(1-indexed)
}

test "reflow: many wide glyphs shrunk to a narrow width does not overflow the scratch" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 12 });
    defer core.deinit();
    // 비-커서 줄을 wide glyph로 가득 채운다(soft-wrap). 좁은 폭에서 wide glyph는 줄 끝 한 칸을
    // 낭비하며 wrap돼, 재배치 행 수가 옛 cap_rows(total_content/new_cols) 추정을 초과한다(힙 OOB였음).
    try core.write("한" ** 80); // 160칸 = 8행의 한(rows 0-7, soft-wrap)
    try core.write("\r\nx"); // 커서를 짧은 줄(아래)로 옮겨 한 줄이 비-커서가 되게 함
    try core.resize(3, 12); // 3칸으로 축소: 한 1개/행 -> ~80행 -> 옛 cap 초과(크래시 없어야)
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(dump.len > 0); // 크래시 없이 통과 + 내용 보존
    try std.testing.expect(core.scrollbackLen() > 0 or std.mem.indexOf(u8, dump, "한") != null);
}

test "eraseInLine mode 1 (erase to cursor) keeps the row's soft-wrap flag" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcde"); // abcd|e: wrapped[0]=true
    try std.testing.expect(core.screen.wrapped[0]);
    try core.write("\x1b[1;2H\x1b[1K"); // CUP (0,1) 후 CSI 1K(시작~커서 지움) — 오른쪽 끝은 멀쩡
    try std.testing.expect(core.screen.wrapped[0]); // mode 1은 wrap 연속성을 안 끊는다
}

test "ECH (CSI Ps X) blanks N cells from the cursor in place, cursor unmoved (nvim mode-label clear)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();
    try core.write("-- INSERT --"); // 12자(col 0~11), 커서 (0,12)
    try core.write("\x1b[1;1H"); // 커서 home(0,0)
    try core.write("\x1b[12X"); // ECH 12 — nvim이 모드 라벨을 지우는 바로 그 시퀀스
    var c: u16 = 0;
    while (c < 12) : (c += 1) {
        const cp = core.screen.cells[core.index(0, c)].codepoint;
        try std.testing.expect(cp == ' ' or cp == 0); // 12칸 전부 blank
    }
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col); // 커서는 제자리(EL과 달리 이동 없음)
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
}

test "ECH default param is 1 and does not pull following cells (not DCH)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 1 });
    defer core.deinit();
    try core.write("ABCDE");
    try core.write("\x1b[1;2H"); // 커서 (0,1)=B
    try core.write("\x1b[X"); // ECH 기본 1 — B만 blank
    const b = core.screen.cells[core.index(0, 1)].codepoint;
    try std.testing.expect(b == ' ' or b == 0);
    try std.testing.expectEqual(@as(u21, 'C'), core.screen.cells[core.index(0, 2)].codepoint); // C는 그대로 — 뒤를 당기지 않는다
}

test "ICH (CSI Ps @) inserts N blanks at the cursor, pushing the rest right and dropping past the edge" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();
    try core.write("abcde");
    try core.write("\x1b[1;2H"); // 커서 (0,1)=b
    try core.write("\x1b[2@"); // ICH 2: b 자리에 빈 칸 2개, bc를 오른쪽으로(de는 edge 넘어 버림)
    try std.testing.expectEqual(@as(u21, 'a'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expect(core.screen.cells[core.index(0, 1)].codepoint == ' ' or core.screen.cells[core.index(0, 1)].codepoint == 0);
    try std.testing.expect(core.screen.cells[core.index(0, 2)].codepoint == ' ' or core.screen.cells[core.index(0, 2)].codepoint == 0);
    try std.testing.expectEqual(@as(u21, 'b'), core.screen.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.screen.cells[core.index(0, 4)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.col); // 커서는 제자리(ICH는 이동 없음)
}

test "DCH (CSI Ps P) deletes N chars, pulling the rest left with blanks at the end; default 1" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();
    try core.write("abcde");
    try core.write("\x1b[1;2H"); // 커서 (0,1)=b
    try core.write("\x1b[2P"); // DCH 2: b,c 삭제, de를 왼쪽으로 당김
    try std.testing.expectEqual(@as(u21, 'a'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.screen.cells[core.index(0, 1)].codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), core.screen.cells[core.index(0, 2)].codepoint);
    try std.testing.expect(core.screen.cells[core.index(0, 3)].codepoint == ' ' or core.screen.cells[core.index(0, 3)].codepoint == 0);
    try std.testing.expect(core.screen.cells[core.index(0, 4)].codepoint == ' ' or core.screen.cells[core.index(0, 4)].codepoint == 0);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.col); // 커서 불변
    try core.write("\x1b[1;1H\x1b[P"); // 커서 home, DCH 기본 1 — a 삭제, d 당김
    try std.testing.expectEqual(@as(u21, 'd'), core.screen.cells[core.index(0, 0)].codepoint);
}

test "DCH pulls a double-width glyph intact when deleting a preceding cell" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();
    try core.write("a한bc"); // a(0) 한(1-2, wide) b(3) c(4)
    try core.write("\x1b[1;1H"); // 커서 home (0,0)=a
    try core.write("\x1b[P"); // DCH 1 — a 삭제, 한이 col0-1로 통째 당겨짐
    try std.testing.expectEqual(@as(u21, '한'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expect(core.screen.cells[core.index(0, 1)].continuation); // 한 base+continuation 정합 유지
    try std.testing.expectEqual(@as(u21, 'b'), core.screen.cells[core.index(0, 2)].codepoint);
}

test "ICH clears a wide glyph base pushed half off the line edge" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();
    try core.write("abc한"); // a(0) b(1) c(2) 한(3-4, wide)
    try core.write("\x1b[1;1H"); // 커서 home
    try core.write("\x1b[@"); // ICH 1 — 한이 줄 끝으로 밀려 continuation이 줄 밖으로
    try std.testing.expectEqual(@as(u21, 'c'), core.screen.cells[core.index(0, 3)].codepoint);
    const last = core.screen.cells[core.index(0, 4)];
    try std.testing.expect(last.codepoint != '한' and last.width != 2); // 고아 base 없이 비워짐
}

test "focus reporting (DECSET 1004): off=무리포트, on=CSI I / CSI O" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    // 기본 off — 포커스 변화를 리포트하지 않는다.
    core.reportFocus(true);
    try std.testing.expectEqualStrings("", core.pendingResponse());
    // DECSET 1004 on — gained=CSI I, lost=CSI O.
    try core.write("\x1b[?1004h");
    core.clearResponse();
    core.reportFocus(true);
    try std.testing.expectEqualStrings("\x1b[I", core.pendingResponse());
    core.clearResponse();
    core.reportFocus(false);
    try std.testing.expectEqualStrings("\x1b[O", core.pendingResponse());
    // DECSET 1004 off(RST) — 다시 무리포트.
    try core.write("\x1b[?1004l");
    core.clearResponse();
    core.reportFocus(true);
    try std.testing.expectEqualStrings("", core.pendingResponse());
}

test "resetInputModes: 입력 모드만 끄고 화면·커서는 보존한다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    // 입력 오염 모드를 켜고(focus·mouse·bracketed·app-cursor·kitty) 화면에 글자를 찍는다.
    try core.write("\x1b[?1004h\x1b[?1000h\x1b[?2004h\x1b[?1h\x1b[>1u");
    try core.write("hi");
    try std.testing.expect(core.focus_events);
    try std.testing.expect(core.mouse_tracking != .none);
    try std.testing.expect(core.bracketed_paste);
    try std.testing.expect(core.application_cursor_keys);
    const cursor_before = core.screen.cursor;

    core.resetInputModes();

    // 입력 모드는 전부 꺼진다.
    try std.testing.expect(!core.focus_events);
    try std.testing.expectEqual(MouseTracking.none, core.mouse_tracking);
    try std.testing.expectEqual(MouseFormat.x10, core.mouse_format);
    try std.testing.expect(!core.bracketed_paste);
    try std.testing.expect(!core.application_cursor_keys);
    try std.testing.expectEqual(@as(usize, 0), core.kitty_flags.depth);
    // 잔류 증상 해소: 포커스를 더는 리포트하지 않는다.
    core.clearResponse();
    core.reportFocus(true);
    try std.testing.expectEqualStrings("", core.pendingResponse());
    // 보이는 내용과 커서는 그대로 보존된다(비파괴).
    try std.testing.expectEqual(cursor_before, core.screen.cursor);
    try std.testing.expectEqual(@as(u21, 'h'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'i'), core.screen.cells[core.index(0, 1)].codepoint);
}

test "mouse reporting (DECSET 1000 + SGR 1006): off=무리포트, press/release/wheel, mode off" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();
    // off — 무리포트.
    core.reportMouse(0, 5, 3, 0, 0, true, false, 0);
    try std.testing.expectEqualStrings("", core.pendingResponse());
    // 1000(normal) + 1006(SGR). left press col5,row3(0-based) → CSI < 0 ; 6 ; 4 M. SGR은 픽셀 무시(셀).
    try core.write("\x1b[?1000h\x1b[?1006h");
    core.clearResponse();
    core.reportMouse(0, 5, 3, 120, 72, true, false, 0);
    try std.testing.expectEqualStrings("\x1b[<0;6;4M", core.pendingResponse());
    // release → 소문자 m.
    core.clearResponse();
    core.reportMouse(0, 5, 3, 120, 72, false, false, 0);
    try std.testing.expectEqualStrings("\x1b[<0;6;4m", core.pendingResponse());
    // wheel-up(64) → CSI < 64 ; 1 ; 1 M.
    core.clearResponse();
    core.reportMouse(64, 0, 0, 0, 0, true, false, 0);
    try std.testing.expectEqualStrings("\x1b[<64;1;1M", core.pendingResponse());
    // 1000 off → 무리포트.
    try core.write("\x1b[?1000l");
    core.clearResponse();
    core.reportMouse(0, 5, 3, 0, 0, true, false, 0);
    try std.testing.expectEqualStrings("", core.pendingResponse());
}

test "mouse reporting SGR-Pixels format (DECSET 1016): 셀이 아니라 픽셀 좌표 리포트" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();
    // 1000(normal) + 1016(SGR-Pixels). 셀(5,3)이어도 픽셀(120,72)을 1-based로 리포트한다 —
    // 같은 입력이 1006이면 셀 6;4였을 자리에 픽셀 121;73이 나와야 한다(이게 1016과 1006의 차이).
    try core.write("\x1b[?1000h\x1b[?1016h");
    core.clearResponse();
    core.reportMouse(0, 5, 3, 120, 72, true, false, 0);
    try std.testing.expectEqualStrings("\x1b[<0;121;73M", core.pendingResponse());
    // release → 소문자 m, 픽셀 좌표 유지.
    core.clearResponse();
    core.reportMouse(0, 5, 3, 120, 72, false, false, 0);
    try std.testing.expectEqualStrings("\x1b[<0;121;73m", core.pendingResponse());
    // 1016 off → format이 x10로 복귀(setPrivateModes 2021: else x10). 픽셀 무시, 셀 32-offset.
    try core.write("\x1b[?1016l");
    core.clearResponse();
    core.reportMouse(0, 5, 3, 120, 72, true, false, 0);
    try std.testing.expectEqualStrings("\x1b[M\x20\x26\x24", core.pendingResponse());
}

test "mouse reporting x10 format (기본): CSI M + 32-offset bytes, press만" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();
    try core.write("\x1b[?1000h"); // normal tracking, x10 인코딩(기본 format)
    core.clearResponse();
    core.reportMouse(0, 5, 3, 0, 0, true, false, 0); // Cb=0→32(0x20), col6→38(0x26), row4→36(0x24)
    try std.testing.expectEqualStrings("\x1b[M\x20\x26\x24", core.pendingResponse());
}

test "renderSnapshot clears a wide-glyph base truncated by narrowing in a scrollback row" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("ab한c\r\nX\r\nY"); // "ab한c"(한 at cols 2-3)이 scroll돼 스크롤백으로
    try std.testing.expect(core.scrollbackLen() >= 1);
    try core.resize(3, 2); // 3칸: 스크롤백 행은 그대로 저장되나, 보일 땐 col 2의 한 base가 잘린다
    core.scrollViewport(@as(isize, @intCast(core.scrollbackLen()))); // 맨 위로
    const snap = core.renderSnapshot();
    // 잘린 한 base(width 2)가 마지막 칸에 남으면 half-glyph가 렌더된다 — 정리됐는지 확인.
    try std.testing.expect(snap.cells[2].width != 2);
}

test "DECSTBM confines scrolling to the region; partial region discards the scrolled-off line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 행0~3 = a,b,c,d
    try core.write("\x1b[2;3r"); // DECSTBM region = 행1~2(1-indexed 2;3), 커서 home으로
    try std.testing.expectEqual(@as(u16, 1), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 2), core.scroll_bottom);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row); // DECSTBM은 커서를 home으로
    try core.write("\x1b[3;1H"); // 커서를 하단 margin(행2)로
    try core.write("\n"); // region [1,2] 위로 스크롤: b 버려지고 c가 행1로, 행2는 빈칸
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nc \n  \nd ", dump); // 행0(a)·행3(d)는 그대로
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // top>0라 스크롤백 보관 안 함
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row); // 커서는 하단 margin 유지
}

test "DECSTBM region at screen top pushes the evicted line to scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[1;3r"); // region = 행0~2(top==0), 커서 home
    try core.write("\x1b[3;1H"); // 하단 margin(행2)
    try core.write("\n"); // region [0,2] 위로: a는 화면 최상단에서 밀려나므로 스크롤백으로
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("b \nc \n  \nd ", dump);
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
}

test "RI scrolls the region down when the cursor is at the top margin" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[1;3r"); // region 행0~2, 커서 home(행0=상단 margin)
    try core.write("\x1bM"); // RI: 상단 margin이라 region을 아래로 — 행0 빈칸, a->행1, b->행2
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("  \na \nb \nd ", dump); // 행3(d)는 region 밖이라 그대로
}

test "BCE: 스크롤로 들어오는 빈 줄·ED가 현재 pen 배경을 잇는다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    try core.write("\x1b[44m"); // 배경 파랑(SGR 44) → pen에 박힘
    const bg = core.screen.pen.background;
    try std.testing.expect(std.meta.activeTag(bg) != .default); // SGR 44가 non-default bg를 세웠다

    // 화면을 채우고 LF로 한 번 스크롤 → 새로 들어온 맨 아래 빈 줄이 pen 배경을 이어야 한다(BCE).
    try core.write("A\r\nB\r\n");
    const scrolled = core.screen.cells[core.index(1, 0)];
    // 텍스트는 없고(안 쓴 칸) 배경만 이어받는다 — `isUnwritten`은 배경이 default일 때만 참이라 여기선 못 쓴다.
    try std.testing.expectEqual(@as(u21, 0), scrolled.codepoint);
    try std.testing.expectEqual(bg, scrolled.style.background);

    // ED(\e[2J)도 같은 규칙: 전체를 pen 배경으로 지운다(기존 동작 고정).
    try core.write("\x1b[2J");
    try std.testing.expectEqual(bg, core.screen.cells[core.index(0, 0)].style.background);
    try std.testing.expectEqual(bg, core.screen.cells[core.index(1, 3)].style.background);
}

test "DECSTBM ignores an invalid (top>=bottom) region and keeps the prior one" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[2;3r"); // region 행1~2 설정
    try core.write("\x1b[4;2r"); // top(3)>=bottom(1) -> 무시
    try std.testing.expectEqual(@as(u16, 1), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 2), core.scroll_bottom);
}

test "DECOM (DECSET ?6): CUP/HVP/VPA rows are relative to the scroll region and clamped within it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 10 });
    defer core.deinit();
    try core.write("\x1b[4;6r"); // DECSTBM: region rows 4~6 (0-based top=3, bottom=5)
    try core.write("\x1b[?6h"); // DECOM on → 커서가 region home(top=3)으로
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
    try core.write("\x1b[1;3H"); // CUP 1;3 → region top, col 2
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);
    try core.write("\x1b[2;1H"); // CUP 2;1 → region top+1 (row 4)
    try std.testing.expectEqual(@as(u16, 4), core.screen.cursor.row);
    try core.write("\x1b[99;1H"); // CUP 큰 값 → region bottom으로 clamp (row 5)
    try std.testing.expectEqual(@as(u16, 5), core.screen.cursor.row);
    try core.write("\x1b[1d"); // VPA 1 → DECOM origin이라 region top(row 3) — 절대였으면 row 0
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.row);
}

test "DECOM off (default): CUP/VPA rows are absolute, ignoring the scroll region" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 10 });
    defer core.deinit();
    try core.write("\x1b[4;6r"); // region 4~6을 설정해도
    try core.write("\x1b[1;1H"); // DECOM off(기본) → CUP 1;1 = 화면 절대 (row 0)
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try core.write("\x1b[8d"); // VPA 8 → row 7 (region 밖이어도 절대)
    try std.testing.expectEqual(@as(u16, 7), core.screen.cursor.row);
}

test "DECOM reset by RIS, reported by DECRQM (?6$p), and DECSTBM homes to region top under DECOM" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 10 });
    defer core.deinit();
    try core.write("\x1b[?6h"); // DECOM on
    try std.testing.expect(core.origin_mode);
    core.clearResponse();
    try core.write("\x1b[?6$p"); // DECRQM 질의 → set(1)
    try std.testing.expectEqualStrings("\x1b[?6;1$y", core.pendingResponse());
    try core.write("\x1b[3;7r"); // DECOM on에서 DECSTBM → 커서를 region 상단(top=2)으로 home
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row);
    try core.write("\x1bc"); // RIS → DECOM off
    try std.testing.expect(!core.origin_mode);
    core.clearResponse();
    try core.write("\x1b[?6$p"); // DECRQM → reset(2)
    try std.testing.expectEqualStrings("\x1b[?6;2$y", core.pendingResponse());
}

test "resize resets the scroll region to full screen" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[2;3r"); // region 행1~2
    try core.resize(2, 6);
    try std.testing.expectEqual(@as(u16, 0), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 5), core.scroll_bottom); // 새 rows-1
}

test "DECSET 1049 switches to a cleared alt screen and restores primary + cursor on exit" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("one\r\ntwo");
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.col);

    try core.write("\x1b[?1049h"); // alt 진입: 커서 저장 + 빈 화면
    try std.testing.expect(core.alt_active);
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("        \n        \n        ", dump);
    }
    try core.write("\x1b[1;1HALT"); // alt에 그리기

    try core.write("\x1b[?1049l"); // 복귀: primary 내용 + 커서 복원
    try std.testing.expect(!core.alt_active);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("one     \ntwo     \n        ", dump);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.col);
}

test "alt screen output never reaches the scrollback and the viewport is locked" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc"); // primary에서 한 줄 스크롤 -> 스크롤백 1
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());

    try core.write("\x1b[?1049h");
    try core.write("1\r\n2\r\n3\r\n4\r\n5"); // alt에서 여러 줄 스크롤
    // alt는 cap=0인 빈 스크롤백이라 출력이 history에 안 쌓이고(push 무동작), primary의 1행도 보관
    // 슬롯에 있어 활성 scrollbackLen()은 0이다(Scrollback 모델 — "alt엔 스크롤백 없음"이 by-construction).
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    core.scrollViewport(1); // alt에선 sb.count==0이라 자연히 잠김(가드 없이)
    try std.testing.expectEqual(@as(usize, 0), core.view_offset);

    try core.write("\x1b[?1049l");
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen()); // primary 스크롤백 복원
    core.scrollViewport(1); // primary 복귀 후엔 다시 동작
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
}

test "per-screen Scrollback: 스왑 불변식(중첩 enter·alt 중 config·alt에서 ED 3·복원)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // primary 스크롤백 누적
    const primary_sb = core.scrollbackLen();
    try std.testing.expect(primary_sb >= 2);

    try core.write("\x1b[?1049h"); // alt 진입 — primary가 saved_sb로 보관됨
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // alt는 빈 스크롤백

    // 중첩 1049h: 이미 alt면 saved_sb(primary)를 다시 덮어쓰지 않아야 한다(early-return).
    try core.write("\x1b[?1049h");
    try core.write("\x1b[?1049l");
    try std.testing.expectEqual(primary_sb, core.scrollbackLen()); // primary 보존

    try core.write("\x1b[?1049h"); // 다시 alt
    // alt 중 config(set_max_scrollback)는 활성(빈) sb가 아니라 primary에 적용돼야 한다.
    core.setMaxScrollback(77);
    try std.testing.expectEqual(@as(usize, 77), core.maxScrollback()); // 보관된 primary cap을 본다
    // alt에서 ED 3(CSI 3J: erase saved lines)은 빈 alt 스크롤백만 건드리고 primary는 보존한다
    // (xterm "alt엔 saved lines 없음" 모델 — primary history를 alt 프로그램이 못 지운다).
    try core.write("\x1b[3J");
    try core.write("\x1b[?1049l"); // 복귀
    try std.testing.expectEqual(primary_sb, core.scrollbackLen()); // ED 3에도 primary 스크롤백 살아있음
    try std.testing.expectEqual(@as(usize, 77), core.maxScrollback()); // 복원 후에도 cap 반영
}

test "rewrap: cap이 count보다 훨씬 커도 OOB 없이 재-wrap한다(회귀, §11 A1 page 저장)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    core.setMaxScrollback(3);
    try core.write("aaaaaa\r\nbbbbbb\r\ncccccc\r\ndddddd\r\neeeeee"); // 스크롤백 3행
    try std.testing.expectEqual(@as(usize, 3), core.scrollbackLen());

    // cap을 크게 올려도(page 저장은 cap/ring 길이 불일치가 구조적으로 불가 — 페이지는 필요 시 자란다)
    // rewrap이 keep=@min(total_out, cap)으로 묶여 안전하다. 과거 OOB 회귀를 막는 가드.
    core.setMaxScrollback(1000);
    try core.resize(2, 2); // 폭 2: 6글자 줄이 3행으로 풀린다 → total_out > 기존 count
    core.scrollViewport(@intCast(core.scrollbackLen())); // 과거 보기 → rewrap 트리거(크래시 없으면 통과)
    try std.testing.expect(core.scrollbackLen() > 0);
}

test "Scrollback.setCap: 상향/하향(드랍 없는 범위)은 행을 보존한다(§11 A1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    core.setMaxScrollback(3);
    try core.write("aaaaaa\r\nbbbbbb\r\ncccccc\r\ndddddd\r\neeeeee"); // 스크롤백 3행
    try std.testing.expectEqual(@as(usize, 3), core.scrollbackLen());

    core.setMaxScrollback(50); // 상향
    try std.testing.expectEqual(@as(usize, 3), core.scrollbackLen()); // 행 보존(드랍 없음)
    try std.testing.expectEqual(@as(usize, 50), core.maxScrollback());
    const oldest = core.scrollbackRow(0).?;
    try std.testing.expectEqual(@as(u21, 'a'), oldest[0].codepoint);

    core.setMaxScrollback(10); // 하향(count 3 < 10이라 드랍 없음) → 행 보존
    try std.testing.expectEqual(@as(usize, 10), core.maxScrollback());
    try std.testing.expectEqual(@as(usize, 3), core.scrollbackLen());
    try std.testing.expectEqual(@as(u21, 'a'), core.scrollbackRow(0).?[0].codepoint); // 내용 그대로
}

test "rewrap commit OOM은 옛 스크롤백 내용을 보존한다(transactional, §11 A1 리뷰)" {
    // 회귀 가드: page 저장의 rewrap commit이 옛 페이지를 clear한 뒤 OOM나면 스크롤백을 조용히 잃던 버그.
    // setup(쓰기·resize)은 실패 없이 끝내고, rewrap 직전부터 off번째 alloc이 실패하게 주입해 rewrap 도중
    // OOM을 일으킨다. 성공이든 OOM이든 스크롤백 전체 내용이 폭과 무관하게 "ABCDEF"로 보존돼야 한다(트랜잭션:
    // 새 페이지가 전부 성공해야 옛 내용을 교체). 부분 손실이면 문자열이 달라진다.
    var off: usize = 0;
    while (off < 40) : (off += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{}); // setup 중엔 실패 없음
        const a = fa.allocator();
        var core = try TerminalCore.init(a, .{ .cols = 4, .rows = 1 });
        defer core.deinit();
        core.setMaxScrollback(10);
        try core.write("AB\r\nCD\r\nEF\r\nGH"); // AB·CD·EF 스크롤백, GH 표시(2칸 줄이라 wrap 없음)
        try std.testing.expectEqual(@as(usize, 3), core.scrollbackLen());
        try core.resize(3, 1); // 폭 변경 → rewrap_pending (아직 실패 주입 전)
        fa.fail_index = fa.alloc_index + off; // 이 시점부터 off번째 alloc이 실패 → rewrap 도중 OOM
        core.scrollViewport(@intCast(core.scrollbackLen())); // 과거 보기 → rewrap 트리거(OOM이면 옛 내용 유지)
        core.scrollToBottom();
        var buf: [16]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < core.scrollbackLen()) : (i += 1) {
            const r = core.scrollbackRow(i) orelse continue;
            for (r) |cell| {
                if (cell.codepoint != ' ' and cell.codepoint != 0 and n < buf.len) {
                    buf[n] = @intCast(cell.codepoint);
                    n += 1;
                }
            }
        }
        try std.testing.expectEqualStrings("ABCDEF", buf[0..n]);
    }
}

// ── §11 A2: 가변폭/trailing-trim (per-row-descriptor arena) ───────────────────────────────────────
// hard 행은 끝 default-cell을 잘라 가변폭으로 저장(메모리 절감), soft-wrap 행은 full(내부 공백 보존 — rewrap
// 정합). 관측 동작은 불변(render가 short 행을 pad). 아래 첫 테스트는 A1(full-width 저장)에선 RED, A2서 GREEN.

test "A2: hard 스크롤백 행은 끝 공백을 trim해 저장한다(가변폭)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 1 });
    defer core.deinit();
    core.setMaxScrollback(10);
    try core.write("hi\r\nxx"); // "hi"(2칸 hard 줄)가 스크롤백으로, xx 표시
    const r = core.scrollbackRow(0).?;
    try std.testing.expectEqual(@as(usize, 2), r.len); // A1: 20(full), A2: 2(trim) — RED→GREEN
    try std.testing.expectEqual(@as(u21, 'h'), r[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'i'), r[1].codepoint);
}

test "A2: soft-wrap 행은 trim하지 않고 full 폭으로 보존한다" {
    // maru는 끝-공백으로 채워 wrap된 행을 hard(wrapped=false)로 보므로 soft 행엔 끝 공백이 없지만, A2의 trim은
    // rewrap 규칙(`if r<j src.len else trimmedLen`)과 동일하게 wrapped_flag로 분기해 soft 행은 절대 줄이지 않는다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.setMaxScrollback(10);
    try core.write("abcde"); // abcd가 'e'로 soft-wrap(wrapped[0]=true), e는 row1
    try core.write("\r\nfg"); // 바닥에서 scroll → abcd(wrapped) 스크롤백으로
    try std.testing.expect(core.scrollbackRowWrapped(0)); // soft-wrap 행
    const r = core.scrollbackRow(0).?;
    try std.testing.expectEqual(@as(usize, 4), r.len); // soft는 full 폭 유지(trim 안 함)
}

test "A2: trim된 행도 스크롤하면 cols 폭으로 pad되어 보인다(render 불변)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    core.setMaxScrollback(10);
    try core.write("ok\r\nzz"); // "ok"(2칸) 스크롤백
    core.scrollViewport(1); // 과거("ok")를 본다
    const snap = core.renderSnapshot();
    try std.testing.expectEqual(@as(u21, 'o'), snap.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'k'), snap.cells[1].codepoint);
    try std.testing.expect(types.isUnwritten(snap.cells[2])); // trim된 뒤는 blank로 pad
    try std.testing.expect(types.isUnwritten(snap.cells[7]));
    try std.testing.expectEqual(@as(usize, 8), snap.cells.len); // 뷰포트는 항상 cols 폭
    core.scrollToBottom();
}

test "A2: 빈(trim된 len-0) 스크롤백 행에서 단어/URL 선택은 크래시 없이 null(§11 A2 리뷰)" {
    // 회귀 가드: A2가 전부-공백 hard 행을 len 0으로 저장하면서, wordBoundsAt가 row_cells[0]을 가드 없이
    // 인덱싱해 빈 스크롤백 행에서 더블클릭/Cmd-hover가 OOB 패닉이던 버그(리뷰 발견·재현).
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    core.setMaxScrollback(10);
    try core.write("\r\nx"); // 빈 줄이 스크롤백으로(전부 공백 → trim len 0), x 표시
    core.scrollViewport(1); // 빈 스크롤백 행을 본다
    core.selectWordAt(0, 0, ""); // 더블클릭 — 크래시 없이(선택 없음)
    try std.testing.expect(core.urlAnchorAt(0, 0, selection.link_scopes_full) == null); // Cmd-hover — 크래시 없이 null
    core.scrollToBottom();
}

test "P4: 스크롤백 cell arena는 주입된 arena allocator를 통해 할당된다(§11 P4)" {
    // setScrollbackArena로 cell arena를 별도 allocator로 라우팅하고, 스크롤백을 채우면 그 allocator를 통해
    // 할당이 일어남을 확인(production은 page_allocator). FailingAllocator는 실패 없이 alloc 횟수를 센다.
    var arena_tracker = std.testing.FailingAllocator.init(std.testing.allocator, .{}); // never-fail, 카운팅
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 80, .rows = 2 });
    defer core.deinit();
    core.setScrollbackArena(arena_tracker.allocator()); // cell arena만 이 allocator로(나머지는 testing)
    core.setMaxScrollback(100);
    const before = arena_tracker.alloc_index;
    var i: usize = 0;
    while (i < 40) : (i += 1) try core.write("page-arena-line\r\n"); // 스크롤백 채움 → cell arena 할당
    try std.testing.expect(core.scrollbackLen() > 0);
    try std.testing.expect(arena_tracker.alloc_index > before); // cell arena가 주입된 allocator를 통과
    // 내용 정합(arena 분리해도 동작 불변): 가장 오래된 행 첫 글자.
    try std.testing.expectEqual(@as(u21, 'p'), core.scrollbackRow(0).?[0].codepoint);
}

test "setMaxScrollback 하향 트림: 가장 오래된 행을 버리고 view_offset을 보정한다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.setMaxScrollback(10);
    try core.write("r0\r\nr1\r\nr2\r\nr3\r\nr4\r\nr5\r\nr6\r\nr7"); // 스크롤백 r0..r5(6행)
    const before = core.scrollbackLen();
    try std.testing.expect(before >= 6);
    try std.testing.expectEqual(@as(u21, '0'), core.scrollbackRow(0).?[1].codepoint); // 가장 오래된 = r0

    core.scrollViewport(@intCast(before)); // 맨 위(가장 오래된)로
    try std.testing.expectEqual(before, core.view_offset);

    core.setMaxScrollback(2); // 하향: 최근 2행만 남기고 가장 오래된 (before-2)행을 버린다
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen()); // 최근 2행만
    try std.testing.expect(core.view_offset <= core.scrollbackLen()); // 버린 과거를 가리키지 않게 클램프
    // 남은 가장 오래된 행은 r4(= before가 6이면 r0..r3 버림). 'r' 접두로 연속성만 확인.
    try std.testing.expectEqual(@as(u21, 'r'), core.scrollbackRow(0).?[0].codepoint);

    core.setMaxScrollback(0); // 끄기: 전부 버리고 페이지 회수
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    try std.testing.expectEqual(@as(usize, 0), core.view_offset);
}

fn mkTestPlacement(anchor_row: usize) StoredPlacement {
    return .{
        .image_id = 1,
        .placement_id = 1,
        .anchor_row = anchor_row,
        .anchor_col = 0,
        .cell_x_offset = 0,
        .cell_y_offset = 0,
        .src_x = 0,
        .src_y = 0,
        .src_width = 0,
        .src_height = 0,
        .columns = 0,
        .rows = 0,
        .z = 0,
    };
}

test "setMaxScrollback 하향 트림: placement anchor를 버린 행 수만큼 당기고 버려진 행 anchor는 제거" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.setMaxScrollback(10);
    try core.write("r0\r\nr1\r\nr2\r\nr3\r\nr4\r\nr5\r\nr6\r\nr7"); // primary 스크롤백 6행
    const before = core.scrollbackLen();
    try std.testing.expect(before >= 6);

    // 살아남을 영역(가장 최근)에 하나, 버려질 영역(가장 오래된, anchor 0)에 하나.
    try core.kitty_placements.append(std.testing.allocator, mkTestPlacement(before - 1));
    try core.kitty_placements.append(std.testing.allocator, mkTestPlacement(0));

    core.setMaxScrollback(2); // 최근 2행만 — drop = before-2
    const drop = before - 2;
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len); // anchor 0짜리는 제거
    try std.testing.expectEqual(before - 1 - drop, core.kitty_placements.items[0].anchor_row); // 살아남은 건 drop만큼 당김
}

test "setMaxScrollback: alt 중 하향 트림은 활성 alt 화면의 placement를 보정하지 않는다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.setMaxScrollback(10);
    try core.write("r0\r\nr1\r\nr2\r\nr3\r\nr4\r\nr5\r\nr6\r\nr7"); // primary 스크롤백 6행
    try std.testing.expect(core.scrollbackLen() >= 6);

    try core.write("\x1b[?1049h"); // alt 진입
    // alt 화면에서 생성된 placement(alt-space anchor — 작은 행 번호). primary 트림과 무관해야 한다.
    try core.kitty_placements.append(std.testing.allocator, mkTestPlacement(1));

    core.setMaxScrollback(2); // parked primary(saved_sb)를 트림(drop>0) — 활성 alt 좌표는 건드리면 안 됨
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len); // 제거 안 됨
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items[0].anchor_row); // 시프트 안 됨

    try core.write("\x1b[?1049l"); // 복귀 — primary 스크롤백은 트림돼 메모리 회수됨
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
}

test "resize during alt: 폭 변경이 복귀 후 primary 스크롤백 재-wrap을 트리거한다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("aaaaaa\r\nbbbbbb\r\ncccccc"); // primary 스크롤백 1행("aaaaaa")
    try std.testing.expect(core.scrollbackLen() >= 1);

    try core.write("\x1b[?1049h"); // alt 진입 — primary는 saved_sb로 보관
    try core.resize(3, 2); // alt 중 폭 변경(6→3)
    try std.testing.expect(core.saved_screen.sb.rewrap_pending); // 보관된 primary가 재-wrap 마크됨
    try core.write("\x1b[?1049l"); // 복귀 — sb=saved_sb(rewrap_pending 동반)
    try std.testing.expect(core.screen.sb.rewrap_pending);
    core.scrollViewport(@intCast(core.scrollbackLen())); // 트리거 → 현재 폭(3)으로 재-wrap
    try std.testing.expect(!core.screen.sb.rewrap_pending); // 소비됨
}

test "DECSET 47 restores the primary cursor on leave (per-screen cursor, §10.8.4 #2)" {
    // per-screen 모델: 커서가 화면에 귀속돼 47/1047도 이탈 시 primary 커서를 swap으로 복원한다(옛 단일-커서
    // 모델은 47에서 복원 안 했음 — §10.8.4 #2의 의도된 동작 변경).
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("hi"); // primary 커서 (0,2)
    try core.write("\x1b[?47h"); // alt 진입 → 커서 home(0,0)
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row); // alt는 home에서 시작(§10.8.4 #1)
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
    try core.write("\x1b[2;5H"); // alt에서 커서 (1,4)로 이동
    try core.write("\x1b[?47l"); // 복귀: primary 커서 (0,2) swap 복원
    try std.testing.expect(!core.alt_active);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi      \n        ", dump); // primary 내용도 복원
}

test "DECSET 1048 saves and restores the cursor without switching screens" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("ab\x1b[?1048h"); // (0,2) 저장
    try core.write("\x1b[2;6H"); // (1,5)로 이동
    try core.write("\x1b[?1048l"); // 복원
    try std.testing.expect(!core.alt_active);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);
}

test "resize while in the alt screen clips both grids and restores a matching primary" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 3 });
    defer core.deinit();
    try core.write("hello\r\nworld");
    try core.write("\x1b[?1049h\x1b[1;1HALTALT");
    try core.resize(4, 2); // alt 중 축소: 둘 다 clip/pad, 스크롤백 push 없음
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("ALTA\n    ", dump); // alt 잘림
    }
    try core.write("\x1b[?1049l"); // 복귀: 잘린 primary
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hell\nworl", dump);
}

test "entering the alt screen twice is a no-op (no buffer leak/overwrite)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("ok");
    try core.write("\x1b[?1049h\x1b[?47h"); // 두 번째 enter는 무시
    try std.testing.expect(core.alt_active);
    try core.write("\x1b[?1049l");
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("ok  \n    ", dump);
}

test "CSI ?1h/l (DECCKM) flips arrow encoding between SS3 and CSI" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    var buffer: [input.encoded_key_buffer_len]u8 = undefined;
    // 기본(normal): CSI 형식
    try std.testing.expectEqualStrings("\x1b[A", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
    try core.write("\x1b[?1h"); // vim이 켜는 application cursor mode
    try std.testing.expect(core.application_cursor_keys);
    try std.testing.expectEqualStrings("\x1bOA", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
    try core.write("\x1b[?1l"); // 끄면 다시 normal
    try std.testing.expectEqualStrings("\x1b[A", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
}

test "DECCKM combined with alt screen (vim startup sequence) round-trips" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    var buffer: [input.encoded_key_buffer_len]u8 = undefined;
    try core.write("\x1b[?1049h\x1b[?1h"); // vim 진입: alt screen + DECCKM
    try std.testing.expect(core.alt_active);
    try std.testing.expectEqualStrings("\x1bOB", try core.encodeKey(.{ .key = .arrow_down }, &buffer));
    try core.write("\x1b[?1l\x1b[?1049l"); // vim 종료
    try std.testing.expect(!core.alt_active);
    try std.testing.expectEqualStrings("\x1b[B", try core.encodeKey(.{ .key = .arrow_down }, &buffer));
}

test "CSI ?1007h/l toggles alternate scroll (default on)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try std.testing.expect(core.alternate_scroll); // iTerm2/Terminal.app처럼 기본 on
    try core.write("\x1b[?1007l");
    try std.testing.expect(!core.alternate_scroll);
    try core.write("\x1b[?1007h");
    try std.testing.expect(core.alternate_scroll);
}

test "IL inserts blank lines at the cursor, pushing rows down within the scroll region" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[2;1H\x1b[L"); // 커서 행1, IL 1: b/c가 내려가고 d는 밀려나감
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \n  \nb \nc ", dump);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col); // IL 후 CR
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // 편집 연산은 history 아님
}

test "DL deletes lines at the cursor, pulling rows up; scroll region confines both" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[2;1H\x1b[M"); // DL 1: b 삭제, c/d가 올라오고 바닥 빈 줄
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("a \nc \nd \n  ", dump);
    }
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());

    // scroll region [1,2]에서 DL: region 밖(행0/3)은 불변, region 하단에만 빈 줄.
    try core.write("\x1b[1;1Ha\r\nb\r\nc\r\nd"); // 화면 재구성 a/b/c/d... 행0부터 덮어씀
    try core.write("\x1b[2;3r\x1b[2;1H\x1b[M"); // region 1~2, 커서 행1, DL
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nc \n  \nd ", dump);
}

test "IL/DL are ignored when the cursor is outside the scroll region" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[2;3r"); // region 1~2
    try core.write("\x1b[4;1H\x1b[L\x1b[M"); // 커서 행3(밖): 둘 다 무시
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nb \nc \nd ", dump);
}

test "DECTCEM (CSI ?25 l/h) hides and shows the cursor in snapshots" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try std.testing.expect(core.snapshot().cursor.visible);
    try core.write("\x1b[?25l");
    try std.testing.expect(!core.snapshot().cursor.visible);
    try std.testing.expect(!core.renderSnapshot().cursor.visible);
    try core.write("\x1b[?25h");
    try std.testing.expect(core.snapshot().cursor.visible);
}

test "SGR 7/27 set and clear reverse video on the pen (0 resets it too)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[7mX");
    try std.testing.expect(core.screen.cells[0].style.reverse);
    try core.write("\x1b[27mY");
    try std.testing.expect(!core.screen.cells[1].style.reverse);
    try core.write("\x1b[7m\x1b[0mZ"); // SGR 0이 reverse도 리셋
    try std.testing.expect(!core.screen.cells[2].style.reverse);
}

test "DECSC/DECRC (ESC 7/8) save and restore the cursor around a DECSTBM reset (claude CLI startup)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("one\r\ntwo");
    // claude CLI 시작 시퀀스: ESC 7(저장), CSI r(region 리셋 — 부수효과로 커서 home), ESC 8(복원).
    try core.write("\x1b7\x1b[r\x1b8!");
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row); // 복원돼 (1,3)에서 이어 그림
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("one     \ntwo!    \n        \n        ", dump);
}

test "DECRC restores the pen and clamps a cursor saved on a larger screen" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[31m\x1b[3;5H\x1b7"); // 빨강 pen + (2,4) 저장
    try core.write("\x1b[0m\x1b[1;1H"); // pen 리셋 + 이동
    try core.write("\x1b8"); // 복원
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.screen.cursor.col);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.screen.pen.foreground);
    try core.resize(4, 2); // 저장 좌표보다 작은 화면으로
    try core.write("\x1b8"); // clamp돼 grid 안
    try std.testing.expect(core.screen.cursor.row < 2 and core.screen.cursor.col < 4);
}

test "CSI s/u (SCOSC/SCORC) save and restore the cursor like DECSC/DECRC" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    // brew 등 multi-line progress가 쓰는 ANSI 커서 저장/복원. (1,4)로 옮겨 CSI s로 저장하고, 다른
    // 데로 옮긴 뒤 CSI u로 복원하면 (1,4)로 돌아와야 한다 — 안 그러면 진행바가 줄줄이 쌓인다.
    try core.write("\x1b[2;5H"); // CUP (1-indexed 2;5) → row1, col4
    try core.write("\x1b[s"); // SCOSC: 저장
    try core.write("\x1b[3;9H"); // row2, col8로 이동
    try core.write("\x1b[u"); // SCORC: 복원 → row1, col4
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.screen.cursor.col);
}

test "restoreFromSlot (CSI u / DECRC) preserves pending_wrap saved at line end" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("ABCD"); // 마지막 칸을 채워 deferred autowrap(pending_wrap=true), 커서는 col3에 머묾
    try core.write("\x1b[s"); // SCOSC: pending_wrap=true 상태로 저장
    try core.write("\x1b[2;1H"); // 다른 줄로 이동 — pending_wrap 해제
    try core.write("\x1b[u"); // SCORC: 복원 → pending_wrap도 true로 돌아와야 한다
    try core.write("E"); // pending_wrap이면 'E'가 먼저 다음 줄로 넘어가 그려진다
    // 복원이 무효화됐으면(버그) 'E'가 row0 col3(D 자리)를 덮는다. 복원되면 D 유지 + E는 다음 줄.
    try std.testing.expectEqual(@as(u21, 'D'), core.screen.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), core.screen.cells[core.index(1, 0)].codepoint);
}

test "DA1 (CSI c) answers with a VT102 identification over the response path" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[c");
    try std.testing.expectEqualStrings("\x1b[?6c", core.pendingResponse());
    core.clearResponse();
    try core.write("\x1b[0c"); // 명시적 0도 동일
    try std.testing.expectEqualStrings("\x1b[?6c", core.pendingResponse());
}

test "OSC 11 (background color) query answers with theme color in xterm rgb format" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    core.setDefaultColors(.{ .r = 0xcc, .g = 0xcc, .b = 0xcc }, .{ .r = 0x10, .g = 0x20, .b = 0x30 });
    try core.write("\x1b]11;?\x1b\\"); // OSC 11 ; ? ST — 배경색 질의(nvim 등이 light/dark 테마 감지에 씀)
    // 8-bit 채널을 16-bit로 복제: 0x10→1010, 0x20→2020, 0x30→3030.
    try std.testing.expectEqualStrings("\x1b]11;rgb:1010/2020/3030\x1b\\", core.pendingResponse());
}

test "OSC 10 (foreground color) query answers; color-set spec is consumed silently (후속)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    core.setDefaultColors(.{ .r = 0xab, .g = 0xcd, .b = 0xef }, .{ .r = 0, .g = 0, .b = 0 });
    try core.write("\x1b]10;?\x1b\\"); // 전경색 질의
    try std.testing.expectEqualStrings("\x1b]10;rgb:abab/cdcd/efef\x1b\\", core.pendingResponse());
    // 질의(?)가 아닌 색 설정(spec)은 후속이라 응답 없이 소비만 한다.
    core.clearResponse();
    try core.write("\x1b]10;#ffffff\x1b\\");
    try std.testing.expectEqualStrings("", core.pendingResponse());
}

test "OSC 52 (clipboard) write decodes base64 into pending; read(?) sets read-pending+target, no core response (F2-6)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // "hi" = base64 "aGk=". OSC 52 ; c ; aGk= ST → 디코드된 "hi"가 clipboard_write pending에.
    try core.write("\x1b]52;c;aGk=\x1b\\");
    try std.testing.expectEqualStrings("hi", core.pendingClipboardWrite());
    try std.testing.expect(!core.clipboardReadPending()); // write는 read pending과 무관

    // 읽기(data가 ?): 코어는 쿼리만 파싱해 read-pending + target("c")을 세운다. 코어는 clipboard_write도 응답도
    // 만들지 않는다(실제 클립보드 읽기·base64 응답·정책 osc52.read은 platform 책임 — write 대칭, 탈취 방지).
    core.clearClipboardWrite();
    try core.write("\x1b]52;c;?\x1b\\");
    try std.testing.expectEqualStrings("", core.pendingClipboardWrite());
    try std.testing.expectEqualStrings("", core.pendingResponse());
    try std.testing.expect(core.clipboardReadPending());
    try std.testing.expectEqualStrings("c", core.clipboardReadTarget());

    // 소비(platform이 정책 확인·응답 후) → pending 비움.
    core.clearClipboardRead();
    try std.testing.expect(!core.clipboardReadPending());
    try std.testing.expectEqualStrings("", core.clipboardReadTarget());

    // target이 다른 Pc(예: p=primary)·빈 값도 그대로 기억한다.
    try core.write("\x1b]52;p;?\x1b\\");
    try std.testing.expectEqualStrings("p", core.clipboardReadTarget());
    core.clearClipboardRead();
    try core.write("\x1b]52;;?\x1b\\"); // 빈 Pc
    try std.testing.expect(core.clipboardReadPending());
    try std.testing.expectEqualStrings("", core.clipboardReadTarget());
}

test "OSC 52: 한 문단 크기(>2KB) 클립보드 쓰기도 통째로 받고, drain 후 버퍼 capacity를 반납한다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // ssh+tmux/nvim 원격 복사(OSC 52)에서 한 문단이 옛 고정 2048 OSC 버퍼를 넘겨 통째로 버려졌다 —
    // "짧은 복사는 되고 문단 복사는 조용히 실패". 동적 버퍼로 받는지 + drain 후 반납(osc_buffer·clipboard_write
    // 둘 다)을 확인한다. 반납 임계치(osc_retain_bytes/clipboard_write_retain_bytes=4096)를 실제로 넘기려면
    // 수집·디코드 버퍼가 모두 4096B를 넘어야 하므로 원문을 넉넉히(~5KB) 잡는다(옛 ~1.7KB는 임계치 미만이라
    // 반납 분기를 안 타 검증이 공허했다).
    const para = "가나다라마바사아자차카타파하 " ** 120; // ≈5.1KB → base64 ~6.9KB(수집·디코드 버퍼 모두 4096 초과)
    const b64 = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(para.len));
    defer std.testing.allocator.free(b64);
    const enc = std.base64.standard.Encoder.encode(b64, para);
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(std.testing.allocator);
    try seq.appendSlice(std.testing.allocator, "\x1b]52;c;");
    try seq.appendSlice(std.testing.allocator, enc);
    try seq.appendSlice(std.testing.allocator, "\x07");
    try std.testing.expect(enc.len > 4096); // 수집 버퍼가 반납 임계치(4096)를 확실히 넘김을 보장
    try core.write(seq.items);
    try std.testing.expectEqualStrings(para, core.pendingClipboardWrite());
    // 대용량 dispatch 뒤 수집 버퍼 capacity는 0으로 반납된다(clearAndFree — 일상 소형 OSC가 수 MB를 안 붙들게).
    try std.testing.expectEqual(@as(usize, 0), core.osc_buffer.capacity);
    // 디코드 버퍼(clipboard_write)도 drain(clearClipboardWrite) 후 capacity 반납 — 세션 내내 16MB 상주 방지.
    try std.testing.expect(core.clipboard_write.capacity > 4096); // drain 전엔 대용량
    core.clearClipboardWrite();
    try std.testing.expectEqual(@as(usize, 0), core.clipboard_write.capacity);
    // 이어지는 소형 OSC도 정상 동작(반납 후 재수집).
    try core.write("\x1b]52;c;aGk=\x1b\\");
    try std.testing.expectEqualStrings("hi", core.pendingClipboardWrite());
}

test "OSC 52: 상한 초과 쓰기는 clipboard_write_rejected를 1회성으로 세운다 (무음 실패 → 가시적 상한)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // 정상 크기 쓰기는 거부 신호를 안 세운다.
    try core.write("\x1b]52;c;aGk=\x07"); // "hi"
    try std.testing.expectEqualStrings("hi", core.pendingClipboardWrite());
    try std.testing.expect(!core.takeClipboardWriteRejected());
    core.clearClipboardWrite();

    // 수집 상한(max_osc_bytes) 초과는 parser overflow로 잡힌다. 실제 16MB를 흘리는 대신, dispatchOsc의 overflow
    // 분기만 결정적으로 치려고 overflow latch를 직접 세운다(21MB write 회피 — 순수 분기 검증). 클립보드(osc_large_ok)
    // 였으면 거부 신호를 세우고, 클립보드가 아니면(제목 등) 안 세운다.
    core.osc_overflow = true;
    core.osc_large_ok = true; // "52;"로 인식돼 대용량 허용됐던 시퀀스가 상한 초과
    parser.dispatchOsc(&core);
    try std.testing.expect(core.takeClipboardWriteRejected());
    try std.testing.expect(!core.takeClipboardWriteRejected()); // 1회성(drain하면 false)
    try std.testing.expectEqualStrings("", core.pendingClipboardWrite()); // 클립보드엔 안 씀

    // 비-클립보드 OSC의 overflow는 거부 신호를 안 세운다.
    core.osc_overflow = true;
    core.osc_large_ok = false; // 제목 등 — 클립보드 아님
    parser.dispatchOsc(&core);
    try std.testing.expect(!core.takeClipboardWriteRejected());
}

test "OSC 52: abort(ESC+비-`\\`)로 끊긴 대용량 수집도 capacity를 반납한다 (비-dispatch 경로 상한 재확립)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // 대용량 OSC 52 본문을 흘리다 ST(ESC \)가 아닌 ESC+X로 중단(abort)하면 dispatch가 안 돼 defer 반납을
    // 안 탄다 — 옛 고정 2048 시절엔 불가능했던 megabyte 상주. abort 경로가 직접 반납해 상한을 재확립하는지 확인.
    // (참고: 스트림이 종료 없이 완전히 끊기는 truncate는 파서가 .osc에 머물러 아직 '수집 중'이므로 정당하게
    //  버퍼를 든다 — 다음 종료/abort나 deinit이 반납한다.)
    const filler = "가나다라마바사아자차카타파하 " ** 120; // ~5.1KB → base64 ~6.9KB
    const b64 = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(filler.len));
    defer std.testing.allocator.free(b64);
    const enc = std.base64.standard.Encoder.encode(b64, filler);
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(std.testing.allocator);
    try seq.appendSlice(std.testing.allocator, "\x1b]52;c;");
    try seq.appendSlice(std.testing.allocator, enc); // 종료(BEL/ST) 없이 이어짐
    try core.write(seq.items);
    try std.testing.expect(core.osc_buffer.capacity > 4096); // 수집 중 — 대용량 보유(정상)

    try core.write("\x1bX"); // ESC+X = abort(ST 아님) → ground, dispatch 없음 → abort 경로가 반납
    try std.testing.expectEqual(@as(usize, 0), core.osc_buffer.capacity);

    // 반납 후에도 다음 OSC는 정상 동작한다.
    try core.write("\x1b]52;c;aGk=\x07");
    try std.testing.expectEqualStrings("hi", core.pendingClipboardWrite());
}

test "OSC 4 (palette) set/query, multi-pair, OSC 104 reset(one/all), RIS clears overrides" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // 설정: OSC 4 ; 1 ; rgb:ff/00/80 ST → 인덱스 1 override.
    try core.write("\x1b]4;1;rgb:ff/00/80\x1b\\");
    try std.testing.expectEqual(types.Rgb{ .r = 0xff, .g = 0x00, .b = 0x80 }, core.palette_override[1].?);

    // 질의(override 있음): 8-bit→16-bit 복제(0xff→ffff, 0x80→8080)로 회신.
    try core.write("\x1b]4;1;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:ffff/0000/8080\x1b\\", core.pendingResponse());
    core.clearResponse();

    // 질의(override 없는 인덱스 9 = 기본 xterm256 bright red {255,0,0}).
    try core.write("\x1b]4;9;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]4;9;rgb:ffff/0000/0000\x1b\\", core.pendingResponse());
    core.clearResponse();

    // 여러 쌍 한 번에(#form·rgb:form 혼용): 인덱스 2·3 동시 설정.
    try core.write("\x1b]4;2;#00ff00;3;rgb:00/00/ff\x1b\\");
    try std.testing.expectEqual(types.Rgb{ .r = 0x00, .g = 0xff, .b = 0x00 }, core.palette_override[2].?);
    try std.testing.expectEqual(types.Rgb{ .r = 0x00, .g = 0x00, .b = 0xff }, core.palette_override[3].?);

    // OSC 104 ; 1 — 인덱스 1만 리셋(2·3은 유지).
    try core.write("\x1b]104;1\x1b\\");
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[1]);
    try std.testing.expect(core.palette_override[2] != null);

    // OSC 104(인덱스 없음) — 전부 리셋.
    try core.write("\x1b]104\x1b\\");
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[2]);
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[3]);

    // 잘못된 spec은 무시(인덱스 4 미설정 유지), RIS(ESC c)는 팔레트 override를 공장 초기화.
    try core.write("\x1b]4;4;bogus\x1b\\");
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[4]);
    try core.write("\x1b]4;5;rgb:11/22/33\x1b\\");
    try std.testing.expect(core.palette_override[5] != null);
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[5]);
}

test "OSC 4 query reflects config_palette base (override > config > xterm256); RIS keeps config" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // platform이 주입하는 config theme.palette base를 흉내(인덱스 1 = {0x12,0x34,0x56}).
    var cfg: [16]?types.Rgb = .{null} ** 16;
    cfg[1] = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    core.setConfigPalette(cfg);

    // (a) OSC4 override가 없고 config base가 있으면 config 색을 회신(xterm256이 아니라).
    try core.write("\x1b]4;1;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:1212/3434/5656\x1b\\", core.pendingResponse());
    core.clearResponse();

    // (b) OSC4 override가 있으면 그게 config base보다 우선.
    try core.write("\x1b]4;1;rgb:aa/bb/cc\x1b\\");
    try core.write("\x1b]4;1;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:aaaa/bbbb/cccc\x1b\\", core.pendingResponse());
    core.clearResponse();

    // (c) RIS(ESC c)는 override만 리셋(config base는 유지) — query는 다시 config 색을 회신해야 한다.
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[1]); // override는 리셋
    try core.write("\x1b]4;1;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:1212/3434/5656\x1b\\", core.pendingResponse()); // config base 살아남음
    core.clearResponse();

    // (d) idx>=16은 config_palette 대상이 아니므로 xterm256으로 회신(인덱스 16 = xterm256 {0,0,0}).
    const exp16 = types.xterm256(16);
    var buf: [48]u8 = undefined;
    const want16 = try std.fmt.bufPrint(&buf, "\x1b]4;16;rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
        exp16.r, exp16.r, exp16.g, exp16.g, exp16.b, exp16.b,
    });
    try core.write("\x1b]4;16;?\x1b\\");
    try std.testing.expectEqualStrings(want16, core.pendingResponse());
    core.clearResponse();
}

test "OSC 10/11 (default fg/bg) set/query/reset; query reflects override; RIS clears" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    core.setDefaultColors(.{ .r = 0xcc, .g = 0xcc, .b = 0xcc }, .{ .r = 0x10, .g = 0x20, .b = 0x30 }); // theme 주입

    // 설정 전 질의: 주입된 theme 배경색.
    try core.write("\x1b]11;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]11;rgb:1010/2020/3030\x1b\\", core.pendingResponse());
    core.clearResponse();

    // OSC 11 배경 설정 → override.
    try core.write("\x1b]11;rgb:00/80/ff\x1b\\");
    try std.testing.expectEqual(types.Rgb{ .r = 0x00, .g = 0x80, .b = 0xff }, core.defaultBgOverride().?);
    // 설정 직후 질의는 set 값을 회신(override 우선).
    try core.write("\x1b]11;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]11;rgb:0000/8080/ffff\x1b\\", core.pendingResponse());
    core.clearResponse();

    // OSC 10 전경 설정(#form).
    try core.write("\x1b]10;#ff0000\x1b\\");
    try std.testing.expectEqual(types.Rgb{ .r = 0xff, .g = 0x00, .b = 0x00 }, core.defaultFgOverride().?);

    // OSC 111 = 배경 리셋(전경 override는 유지).
    try core.write("\x1b]111\x1b\\");
    try std.testing.expectEqual(@as(?types.Rgb, null), core.defaultBgOverride());
    try std.testing.expect(core.defaultFgOverride() != null);
    // 리셋 후 질의는 다시 주입 theme 배경.
    try core.write("\x1b]11;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]11;rgb:1010/2020/3030\x1b\\", core.pendingResponse());
    core.clearResponse();

    // OSC 110 = 전경 리셋, RIS도 색 설정 공장 초기화.
    try core.write("\x1b]110\x1b\\");
    try std.testing.expectEqual(@as(?types.Rgb, null), core.defaultFgOverride());
    try core.write("\x1b]10;rgb:11/22/33\x1b\\");
    try std.testing.expect(core.defaultFgOverride() != null);
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(@as(?types.Rgb, null), core.defaultFgOverride());
}

test "OSC 9/777 desktop notification: parse iTerm2/rxvt, ConEmu sub-commands ignored" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try std.testing.expect(core.pendingNotification() == null);

    // OSC 9 ; <message> → iTerm2 알림(title 없음, body=메시지).
    try core.write("\x1b]9;Build finished\x1b\\");
    const first_generation = core.pendingNotification().?.generation;
    {
        const n = core.pendingNotification().?;
        try std.testing.expectEqualStrings("", n.title);
        try std.testing.expectEqualStrings("Build finished", n.body);
    }
    core.clearNotification();
    try std.testing.expect(core.pendingNotification() == null);

    // OSC 777 ; notify ; <title> ; <body> → rxvt 알림.
    try core.write("\x1b]777;notify;Deploy;done in 3s\x1b\\");
    {
        const n = core.pendingNotification().?;
        try std.testing.expectEqualStrings("Deploy", n.title);
        try std.testing.expectEqualStrings("done in 3s", n.body);
    }
    try std.testing.expect(!core.clearNotificationIfGeneration(first_generation));
    try std.testing.expect(core.pendingNotification() != null);
    core.clearNotification();

    // body에 ';'가 더 있어도 첫 ';'만 title/body 경계(body는 ';' 포함 가능).
    try core.write("\x1b]777;notify;T;a;b;c\x1b\\");
    {
        const n = core.pendingNotification().?;
        try std.testing.expectEqualStrings("T", n.title);
        try std.testing.expectEqualStrings("a;b;c", n.body);
    }
    core.clearNotification();

    // ConEmu 서브커맨드는 알림으로 오발사 안 함: 9;4 progress(진행바 폭탄 방지)·9;1 sleep.
    try core.write("\x1b]9;4;1;50\x1b\\");
    try std.testing.expect(core.pendingNotification() == null);
    try std.testing.expectEqualStrings("4;1;50", core.agentProgress());
    try core.write("\x1b]9;4;0\x1b\\");
    try std.testing.expectEqualStrings("4;0", core.agentProgress());
    core.clearAgentProgress();
    try std.testing.expectEqualStrings("", core.agentProgress());
    try core.write("\x1b]9;1;420\x1b\\");
    try std.testing.expect(core.pendingNotification() == null);

    // 선두 숫자라도 다음이 ';'가 아니면(숫자+공백/글자) iTerm2 알림으로 발사.
    try core.write("\x1b]9;42 builds done\x1b\\");
    {
        const n = core.pendingNotification().?;
        try std.testing.expectEqualStrings("42 builds done", n.body);
    }
    core.clearNotification();

    // OSC 777의 notify 외 서브타입은 무시.
    try core.write("\x1b]777;precmd\x1b\\");
    try std.testing.expect(core.pendingNotification() == null);

    core.notification_generation = std.math.maxInt(u64);
    try core.write("\x1b]9;must not wrap\x1b\\");
    try std.testing.expect(core.pendingNotification() == null);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        core.notification_generation,
    );
}

test "P4 N2a notification overflow classifies OSC 9 and 777 without ConEmu false positive" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.osc_buffer.appendSlice(core.allocator, "777;notify;title;oversized");
    core.osc_overflow = true;
    parser.dispatchOsc(&core);
    try std.testing.expect(core.takeNotificationWriteRejected());
    try std.testing.expect(!core.takeNotificationWriteRejected());

    try core.osc_buffer.appendSlice(core.allocator, "9;plain oversized notification");
    core.osc_overflow = true;
    parser.dispatchOsc(&core);
    try std.testing.expect(core.takeNotificationWriteRejected());

    try core.osc_buffer.appendSlice(core.allocator, "9;4;1;oversized-progress");
    core.osc_overflow = true;
    parser.dispatchOsc(&core);
    try std.testing.expect(!core.takeNotificationWriteRejected());
}

test "OSC notification allocation failure preserves prior payload and generation atomically" {
    inline for (0..3) |fail_index| {
        var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
        defer core.deinit();
        osc.dispatchNotify777(&core, "notify;old-title;old-body");
        const before = core.pendingNotification().?;
        const generation_before = before.generation;
        try std.testing.expectEqualStrings("old-title", before.title);
        try std.testing.expectEqualStrings("old-body", before.body);

        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        core.allocator = failing.allocator();
        osc.dispatchNotify777(
            &core,
            "notify;replacement-title-that-allocates;replacement-body-that-allocates",
        );
        core.allocator = std.testing.allocator;
        const after = core.pendingNotification().?;
        if (fail_index < 2) {
            try std.testing.expectEqual(generation_before, after.generation);
            try std.testing.expectEqualStrings("old-title", after.title);
            try std.testing.expectEqualStrings("old-body", after.body);
        } else {
            try std.testing.expectEqual(generation_before + 1, after.generation);
            try std.testing.expectEqualStrings(
                "replacement-title-that-allocates",
                after.title,
            );
            try std.testing.expectEqualStrings(
                "replacement-body-that-allocates",
                after.body,
            );
        }
    }
}

test "dumpRecentUtf8 bounds rows and bytes without splitting UTF-8" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("one\r\ntwo\r\n한글");

    const rows = try core.dumpRecentUtf8(std.testing.allocator, 2, 64);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqualStrings("two \n한글", rows);

    const bounded = try core.dumpRecentUtf8(std.testing.allocator, 3, 5);
    defer std.testing.allocator.free(bounded);
    try std.testing.expect(bounded.len <= 5);
    try std.testing.expect(std.unicode.Utf8View.init(bounded) != error.InvalidUtf8);
}

test "dumpRecentTextUtf8 anchors at last text row while dumpRecentUtf8 keeps physical bottom" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 8 });
    defer core.deinit();
    try core.write("header\r\nstatus"); // text는 row 0..1, row 2..7은 resize 뒤 TUI가 남긴 blank padding을 흉내 낸다.

    const recent = try core.dumpRecentTextUtf8(std.testing.allocator, 2, 128);
    defer std.testing.allocator.free(recent);
    try std.testing.expectEqualStrings("header  \nstatus  ", recent);

    const physical = try core.dumpRecentUtf8(std.testing.allocator, 2, 128);
    defer std.testing.allocator.free(physical);
    try std.testing.expectEqualStrings("        \n        ", physical);
}

test "dumpRecentTextUtf8 bounds trailing blank cell scan" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = recent_text_blank_scan_rows + 2 });
    defer core.deinit();
    try core.write("x"); // text가 scan 상한보다 위에 있으면 오래된 근거를 끌어오지 않고 blank tail로 안전하게 실패한다.

    const recent = try core.dumpRecentTextUtf8(std.testing.allocator, 2, 64);
    defer std.testing.allocator.free(recent);
    try std.testing.expectEqualStrings("  \n  ", recent);
}

test "G3 charset: ESC ( 0 dec_special (G0), SO/SI invoke G1/G0, ESC ( B restores, RIS resets" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();

    // ESC ( 0 → G0=dec_special. GL=G0(기본)이라 'q'→─, 'x'→│. 그 뒤 ESC ( B → G0=ascii 복귀, 'q'는 그대로.
    try core.write("\x1b(0qx\x1b(Bq");
    // 둘째 줄: ESC ) 0 → G1=dec_special. SO(0x0e)로 G1 호출 → 'l'→┌, 'q'→─. SI(0x0f)로 G0(ascii) 복귀 → 'l'.
    try core.write("\r\n\x1b)0\x0elq\x0fl");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("─│q     \n┌─l     ", dump);
    }

    // RIS는 charset도 공장 초기화: dec_special 지정 후 RIS → 'q'는 다시 ascii(변환 안 됨).
    try core.write("\x1b(0\x1bcq");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("q       \n        ", dump);
    }
}

test "G4 tabstops: default 8, HTS sets, CBT back, TBC clears, RIS/resize default" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 30, .rows = 2 });
    defer core.deinit();

    // 기본 탭스톱 8칸: col 0 → TAB → 8 → TAB → 16.
    try core.write("\t");
    try std.testing.expectEqual(@as(u16, 8), core.screen.cursor.col);
    try core.write("\t");
    try std.testing.expectEqual(@as(u16, 16), core.screen.cursor.col);

    // CBT(CSI Z): 역방향 한 탭스톱 → 8. CBT 2개: 8 → 0.
    try core.write("\x1b[Z");
    try std.testing.expectEqual(@as(u16, 8), core.screen.cursor.col);
    try core.write("\x1b[2Z");
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);

    // HTS(ESC H): col 3에 탭스톱 설정 → col 0에서 TAB은 3(기본 8보다 먼저).
    try core.write("\x1b[4G\x1bH"); // CHA col 3(1-based 4) + HTS
    try core.write("\r\t");
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.col);

    // TBC(CSI g 기본 0): col 3 탭스톱 제거 → TAB은 다시 8.
    try core.write("\x1b[4G\x1b[g\r\t");
    try std.testing.expectEqual(@as(u16, 8), core.screen.cursor.col);

    // TBC 3(전체 제거): TAB은 마지막 칸(cols-1=29)으로.
    try core.write("\x1b[3g\r\t");
    try std.testing.expectEqual(@as(u16, 29), core.screen.cursor.col);

    // RIS는 탭스톱을 8칸 기본으로 복원.
    try core.write("\x1bc\t");
    try std.testing.expectEqual(@as(u16, 8), core.screen.cursor.col);

    // resize(폭 변경) 후에도 8칸 기본 유지(새 열 포함): 0→8→16→24→32.
    try core.resize(40, 2);
    try core.write("\r\t\t\t\t");
    try std.testing.expectEqual(@as(u16, 32), core.screen.cursor.col);
}

test "G12 BEL/NEL/VT/FF: bell pending(once), NEL=CR+LF, VT/FF=LF(col 유지)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();

    // BEL(0x07): bell_pending set, takeBell이 한 번 true 후 소비(false).
    try std.testing.expect(!core.takeBell());
    try core.write("\x07");
    try std.testing.expect(core.takeBell());
    try std.testing.expect(!core.takeBell());

    // NEL(ESC E): CR+LF — col 5에서 → 다음 줄 0열.
    try core.write("abcde");
    try std.testing.expectEqual(@as(u16, 5), core.screen.cursor.col);
    try core.write("\x1bE");
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);

    // VT(0x0b)/FF(0x0c): LF처럼 한 줄 내림(col 유지). col 3에서 VT→row2·col3, FF→row3·col3.
    try core.write("xyz");
    try core.write("\x0b");
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.col);
    try core.write("\x0c");
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.col);
}

test "G5/6/7/8/11/13 small gaps: REP, DECALN, IRM, DECAWM off, SU, urxvt mouse" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 4 });
    defer core.deinit();

    // G5 REP(CSI Ps b): 'a' 출력 후 CSI 3 b → 'a' 3개 더 반복 → "aaaa".
    try core.write("a\x1b[3b");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expect(std.mem.startsWith(u8, dump, "aaaa"));
    }

    // 회귀: REP는 '표시된 글리프'를 반복한다 — 출력 후 charset이 바뀌어도 재변환하지 않는다. ASCII에서 'q'
    // 출력 → dec_special(ESC ( 0) 전환 → REP는 'q'를 반복(box `─`로 재변환 아님). putCell 직접 호출로 보장.
    try core.write("\x1bcq\x1b(0\x1b[2b");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expect(std.mem.startsWith(u8, dump, "qqq"));
    }

    // G11 DECALN(ESC # 8): 화면 전체 'E', 커서 home.
    try core.write("\x1b#8");
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("EEEEEE\nEEEEEE\nEEEEEE\nEEEEEE", dump);
    }

    // G6 IRM(CSI 4h): insert mode. "Xb" 위 home에서 IRM on + "A" → "AXb"(X가 오른쪽으로 밀림).
    try core.write("\x1bcXb\x1b[H\x1b[4hA");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expect(std.mem.startsWith(u8, dump, "AXb"));
    }

    // G8 DECAWM off(?7l): 마지막 칸에서 wrap 안 함(덮어쓰기). cols=6: "wxyz12" 채우고 '3'은 마지막 칸 덮어씀.
    try core.write("\x1bc\x1b[?7lwxyz123");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expect(std.mem.startsWith(u8, dump, "wxyz13"));
    }

    // G7 SU(CSI S): scroll region 위로 1줄 팬. row0=11/row1=22/row2=33 → SU → row0=22, row1=33.
    try core.write("\x1bc11\r\n22\r\n33\x1b[S");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expect(std.mem.startsWith(u8, dump, "22"));
        try std.testing.expect(std.mem.indexOf(u8, dump, "33") != null);
    }

    // G13 mouse urxvt(?1015h): mouse_format이 urxvt로 전환(인코딩은 x10 Cb를 십진 CSI Cb;Px;Py M로).
    try core.write("\x1b[?1015h");
    try std.testing.expectEqual(MouseFormat.urxvt, core.mouse_format);
    try core.write("\x1b[?1015l");
    try std.testing.expectEqual(MouseFormat.x10, core.mouse_format);
}

test "G9 DECSCNM: CSI ?5 h/l toggles reverse_screen, RIS resets" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try std.testing.expect(!core.reverseScreen());
    try core.write("\x1b[?5h");
    try std.testing.expect(core.reverseScreen());
    try core.write("\x1b[?5l");
    try std.testing.expect(!core.reverseScreen());
    try core.write("\x1b[?5h\x1bc"); // set + RIS
    try std.testing.expect(!core.reverseScreen());
}

test "G1 SGR ext: blink(5/25), conceal(8/28), double-underline(21), underline color(58/59)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // SGR 5(blink)·8(conceal)·21(double→underline)·58;2;10;20;30(underline color) → pen에 반영.
    try core.write("\x1b[5;8;21;58;2;10;20;30mA");
    const c0 = core.screen.cells[core.index(0, 0)];
    try std.testing.expect(c0.style.blink);
    try std.testing.expect(c0.style.conceal);
    try std.testing.expect(c0.style.underline);
    try std.testing.expectEqual(types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, c0.style.underline_color);

    // SGR 25(blink off)·28(reveal)·24(underline off)·59(underline color default) → 끄기.
    try core.write("\x1b[25;28;24;59mB");
    const c1 = core.screen.cells[core.index(0, 1)];
    try std.testing.expect(!c1.style.blink);
    try std.testing.expect(!c1.style.conceal);
    try std.testing.expect(!c1.style.underline);
    try std.testing.expectEqual(types.Color.default, c1.style.underline_color);

    // 58;5;n(indexed) underline color.
    try core.write("\x1b[58;5;42mC");
    try std.testing.expectEqual(types.Color{ .indexed = 42 }, core.screen.cells[core.index(0, 2)].style.underline_color);
}

test "G14 DCS/DECRQSS: SGR(m), DECSTBM(r), cursor style( q), invalid → DCS 0 \\$r" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();

    // 기본 pen에서 SGR 질의: DCS $ q m ST → DCS 1 $ r 0 m ST.
    try core.write("\x1bP$qm\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1$r0m\x1b\\", core.pendingResponse());
    core.clearResponse();

    // bold+underline+fg red(31) 설정 후 SGR 질의 → 0;1;4;31.
    try core.write("\x1b[1;4;31m\x1bP$qm\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1$r0;1;4;31m\x1b\\", core.pendingResponse());
    core.clearResponse();

    // fg 256색(38;5;200) + underline color rgb(58;2;1;2;3) → 그대로 재구성.
    try core.write("\x1b[0;38;5;200;58;2;1;2;3m\x1bP$qm\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1$r0;38;5;200;58;2;1;2;3m\x1b\\", core.pendingResponse());
    core.clearResponse();

    // DECSTBM 질의: scroll region 2..4 설정 후 DCS $ q r → DCS 1 $ r 2;4 r ST.
    try core.write("\x1b[2;4r\x1bP$qr\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1$r2;4r\x1b\\", core.pendingResponse());
    core.clearResponse();

    // 커서 스타일 질의: DECSCUSR 2(고정 block) → DCS $ q SP q → 1 $ r 2 SP q.
    try core.write("\x1b[2 q\x1bP$q q\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1$r2 q\x1b\\", core.pendingResponse());
    core.clearResponse();

    // 미지원 설정 질의 → DCS 0 $ r ST(invalid).
    try core.write("\x1bP$qZ\x1b\\");
    try std.testing.expectEqualStrings("\x1bP0$r\x1b\\", core.pendingResponse());
}

test "G10 DECKPAM/DECKPNM (ESC =/ESC >): keypad mode toggles, RIS resets, no screen leak" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try std.testing.expect(!core.application_keypad);
    try core.write("\x1b="); // DECKPAM → application
    try std.testing.expect(core.application_keypad);
    try core.write("\x1b>"); // DECKPNM → numeric
    try std.testing.expect(!core.application_keypad);
    try core.write("\x1b=\x1bc"); // set + RIS → numeric 복원
    try std.testing.expect(!core.application_keypad);
    // ESC =/> 는 화면에 텍스트로 새지 않는다(상태만).
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("    ", dump);
}

test "DECSC inside the alt screen does not clobber the cursor saved by 1049 (per-screen slots)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("one\r\ntwo"); // 셸 커서 (1,3)
    try core.write("\x1b[?1049h"); // 셸 커서를 primary 슬롯에 저장
    try core.write("\x1b[3;5H\x1b7\x1b[1;1H\x1b8"); // alt 안에서 ESC 7/8 사용(claude 패턴)
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row); // alt 슬롯 복원 동작
    try core.write("\x1b[?1049l!"); // 종료: primary 슬롯에서 셸 커서 복원
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("one     \ntwo!    \n        \n        ", dump);
}

test "1049l while already on the primary screen is a no-op (per-screen cursor, §10.8.4 #4)" {
    // per-screen 모델: leave는 보관된 화면을 swap 복원하는 것이라, 이미 primary면(swap 대상 없음) no-op이다.
    // 옛 단일-커서 모델은 1049l-while-primary가 저장 슬롯에서 커서를 방어적 복원했으나, stale 슬롯에서 커서를
    // 순간이동시키는 위험이 있어 per-screen에선 커서를 그대로 둔다(§10.8.4 #4 — 의도된 엣지 동작 변경).
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ab\x1b[?1049h\x1b[?47l"); // 1049 진입 후 47로 이탈 → primary 커서 (0,2) 복원됨
    try core.write("\x1b[3;7H"); // 커서를 (2,6)으로
    try core.write("\x1b[?1049l"); // 이미 primary → no-op
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 6), core.screen.cursor.col);
}

// ── B4 per-screen 커서 모델 동작 핀 (Option 3, §10.8) ─────────────────────────────────────────────
// 커서·pen·deferred-wrap·combining 앵커가 화면(Screen)에 귀속돼 alt 전환 시 grid·스크롤백과 함께 통째 swap된다.
// 아래는 그 의도된 동작 변경(§10.8.4)을 핀하는 회귀 가드 묶음 — "동작 보존"이 아니라 "바뀐 동작 검증".

test "1049 round-trip: alt starts home, primary cursor restored on leave (per-screen, §10.8.4 #1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[2;4Hpri"); // primary 커서 (1,3) → "pri" → (1,6)
    try core.write("\x1b[?1049h"); // alt 진입 → home
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
    try core.write("\x1b[3;5HX"); // alt 커서 (2,4) → (2,5)
    try core.write("\x1b[?1049l"); // 복귀 → primary 커서 (1,6) swap 복원
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 6), core.screen.cursor.col);
}

test "alt screen has an independent pen, restored on leave (per-screen, §10.8)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b[1mX"); // primary: bold on → pen.bold=true
    try std.testing.expect(core.screen.pen.bold);
    try core.write("\x1b[?1049h"); // alt 진입 → pen 기본(bold=false)
    try std.testing.expect(!core.screen.pen.bold);
    try core.write("Y"); // alt 일반 글자
    try core.write("\x1b[?1049l"); // 복귀 → primary pen(bold=true) 복원
    try std.testing.expect(core.screen.pen.bold);
}

test "1049h does not clobber the primary DECSC slot (per-screen fix, §10.8.4 #3)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("hello"); // 커서 (0,5)
    try core.write("\x1b7"); // DECSC: primary 화면 saved_cursor = (0,5)
    try core.write("\x1b[1;1H"); // 커서 (0,0)으로
    try core.write("\x1b[?1049h"); // 옛 모델은 여기서 live (0,0)을 primary 슬롯에 덮어썼다 — 이제 안 덮음
    try core.write("\x1b[2;3Hzz"); // alt 활동
    try core.write("\x1b[?1049l"); // 복귀 → primary 커서 (0,0)
    try core.write("\x1b8"); // DECRC: 슬롯이 안 덮였으면 (0,5) 복원
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 5), core.screen.cursor.col);
}

test "resize while in the alt screen clamps the parked primary cursor (per-screen, B4)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[4;7H"); // primary 커서 (3,6)
    try core.write("\x1b[?1049h"); // alt 진입 — primary (3,6) 보관
    try core.resize(3, 2); // 축소 cols=3 rows=2 → 보관 primary 커서가 clamp 안 되면 OOB로 복귀
    try core.write("\x1b[?1049l"); // 복귀 → clamp된 (1,2)
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);
}

test "1049h while already on the alt screen does not disturb the alt cursor (§10.8.4 #4)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b[?1049h"); // alt 진입 → home
    try core.write("\x1b[2;5HZ"); // alt 커서 (1,4) → (1,5)
    try core.write("\x1b[?1049h"); // 이미 alt → no-op
    try std.testing.expect(core.alt_active);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 5), core.screen.cursor.col);
}

test "deferred autowrap state survives an alt round-trip on the primary (per-screen, B4)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcd"); // 마지막 칸 채움 → pending_wrap, 커서 (0,3)
    try std.testing.expect(core.screen.pending_wrap);
    try core.write("\x1b[?1049h"); // alt 진입 → pending_wrap=false(fresh)
    try std.testing.expect(!core.screen.pending_wrap);
    try core.write("\x1b[?1049l"); // 복귀 → primary deferred-wrap 상태 복원
    try std.testing.expect(core.screen.pending_wrap);
    try core.write("e"); // deferred wrap 발동 → 다음 줄 첫 칸
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("abcd\ne   \n    ", dump);
}

// ── B5 per-screen DECSC 슬롯 (saved_cursor가 화면 귀속·swap, §10.8.5) ───────────────────────────────

test "primary DECSC slot survives an alt round-trip, alt ESC 7 cannot clobber it (per-screen, B5)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("hello\x1b7"); // 커서 (0,5), DECSC → primary 슬롯 (0,5)
    try core.write("\x1b[?1049h"); // alt 진입 — primary 슬롯이 saved_screen으로 보관
    try core.write("\x1b[2;3HZ\x1b7"); // alt에서 ESC 7 → alt 슬롯(primary 슬롯 불간섭)
    try core.write("\x1b[?1049l"); // 복귀 → primary 슬롯 (0,5) swap 복원
    try core.write("\x1b[1;1H"); // 커서 (0,0)으로
    try core.write("\x1b8"); // DECRC → primary 슬롯 (0,5) 복원
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 5), core.screen.cursor.col);
}

test "alt DECSC slot is fresh on each alt entry (per-screen, §10.8.5 B5)" {
    // alt는 매 진입 재생성이라 alt 슬롯도 fresh — 옛 평평 saved_cursor_alt의 세션 간 persist는 의도적으로 사라진다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b[?1049h"); // alt 진입 #1
    try core.write("\x1b[2;5H\x1b7"); // alt에서 ESC 7 → alt 슬롯 (1,4)
    try core.write("\x1b[?1049l"); // 이탈(alt 폐기)
    try core.write("\x1b[?1049h"); // alt 진입 #2 → 슬롯 fresh(.{})
    try core.write("\x1b[1;1H"); // 커서 (0,0)
    try core.write("\x1b8"); // DECRC → fresh 슬롯 (0,0) 복원(옛 모델은 (1,4))
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
}

test "CSI s/u (SCO save/restore) use the active screen's saved_cursor (B5)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ab\x1b[s"); // 커서 (0,2), CSI s 저장
    try core.write("\x1b[3;6H"); // (2,5)로
    try core.write("\x1b[u"); // CSI u 복원 → (0,2)
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);
}

test "RIS clears the DECSC saved-cursor slot (xterm power-on reset)" {
    // 베이스: VT100 RIS = power-on 상태 + Ghostty Screen.reset() saved_cursor=null. RIS 후 DECRC는 home 복원.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("hello\x1b7"); // 커서 (0,5), DECSC → 슬롯 (0,5)
    try core.write("\x1bc"); // RIS — 슬롯도 공장 초기화
    try core.write("\x1b[2;3H"); // 커서 (1,2)로
    try core.write("\x1b8"); // DECRC → RIS가 슬롯을 비웠으면 home (0,0)
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
}

test "resize while in the alt screen preserves the saved primary's soft-wrap flags" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("abcdef"); // abcd|ef soft-wrap: wrapped[0]=true
    try std.testing.expect(core.screen.wrapped[0]);
    try core.write("\x1b[?1049h");
    try core.resize(4, 3); // alt 중 행 수만 축소
    try core.write("\x1b[?1049l");
    try std.testing.expect(core.screen.wrapped[0]); // primary 복원 후에도 wrap 메타데이터 생존
}

test "region scrolls break stale soft-wrap links at the range boundaries" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    // 행2-3에 걸친 soft-wrap 줄을 만든다: 행0/1 채우고 "abcdef"(행2 abcd|행3 ef).
    try core.write("x\r\ny\r\nabcdef");
    try std.testing.expect(core.screen.wrapped[2]);
    // 커서 행3에서 IL: 행3이 비고 wrapped[2]의 연속 주장은 깨져야 한다.
    try core.write("\x1b[L");
    try std.testing.expect(!core.screen.wrapped[2]);
    // resize가 빈 행을 이전 줄에 합치지 않는다.
    try core.resize(8, 4);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("x       \ny       \nabcd    \n        ", dump);
}

test "EL and ED clear the deferred-autowrap state (xterm behavior)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcd"); // 마지막 칸 채움 -> pending_wrap
    try std.testing.expect(core.screen.pending_wrap);
    try core.write("\x1b[K!"); // EL 0 후 글자: wrap 없이 같은 행에 찍혀야 한다
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    try core.write("\x1b[2J");
    try std.testing.expect(!core.screen.pending_wrap); // ED도 동일
}

test "a CSI split across writes survives a resize in between (parser state kept)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[31"); // SGR 빨강의 앞부분(쪼개진 read)
    try core.resize(10, 3); // 시퀀스 한가운데 resize
    try core.write("mX"); // 꼬리 도착: 'm'은 글자가 아니라 SGR 완성이어야 한다
    try std.testing.expectEqual(@as(u21, 'X'), core.screen.cells[0].codepoint);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.screen.cells[0].style.foreground);
}

test "CSI sequences with intermediates are consumed, not dispatched as their bare final" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[2;3r"); // region [1,2]
    try core.write("\x1b[1;1;2;2$r"); // DECCARA($r) — DECSTBM으로 오발동하면 region이 바뀐다
    try std.testing.expectEqual(@as(u16, 1), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 2), core.scroll_bottom);
}

test "DA2 (CSI > c) is answered and '>'-marked sequences never leak into SGR" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[>c");
    try std.testing.expectEqualStrings("\x1b[>1;10;0c", core.pendingResponse());
    core.clearResponse();
    try core.write("\x1b[>4;2m"); // modifyOtherKeys — SGR(4;2=underline)로 새면 안 된다
    try core.write("X");
    try std.testing.expect(!core.screen.cells[0].style.underline);
}

test "ED 3 (CSI 3J) clears the scrollback while ED 2 keeps it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백 2줄 생성
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try core.write("\x1b[2J");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen()); // ED 2는 화면만
    core.scrollViewport(1);
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
    try core.write("\x1b[3J"); // E3: history까지 비우고 뷰포트도 바닥으로
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    try std.testing.expectEqual(@as(usize, 0), core.view_offset);
    try core.write("x\r\ny\r\nz"); // 비운 뒤 ring 재사용이 정상인지(커서가 바닥이라 2회 스크롤)
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
}

test "IL/DL with count > 1 move the block once (CSI 2L / CSI 2M)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[1;1H\x1b[2L"); // 행0에 빈 줄 2개 삽입: _,_,a,b
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("  \n  \na \nb ", dump);
    }
    try core.write("\x1b[2M"); // 행0부터 2줄 삭제: a,b,_,_
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nb \n  \n  ", dump);
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
}

test "scrollback rows re-wrap to the new width when the user scrolls back after a resize" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // "abcdefgh" 한 줄(8칸 꽉 참 — hard)과 "xy"가 스크롤백으로 밀린다.
    try core.write("abcdefgh\r\nxy\r\n1\r\n2");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());

    try core.resize(4, 2); // 좁힘: 스크롤백의 "abcdefgh"는 4칸 두 행이 되어야 한다
    core.scrollViewport(10); // 과거 보기(여기서 지연 재-wrap 수행) — 맨 위로
    try std.testing.expectEqual(@as(usize, 3), core.scrollbackLen()); // abcd|efgh|xy
    try std.testing.expectEqualSlices(u8, "abcd", &cellsText4(core.scrollbackRow(0).?));
    try std.testing.expectEqualSlices(u8, "efgh", &cellsText4(core.scrollbackRow(1).?));
    try std.testing.expect(core.scrollbackRowWrapped(0)); // abcd -> efgh 연속
    try std.testing.expect(!core.scrollbackRowWrapped(1)); // efgh는 hard 끝

    try core.resize(8, 2); // 다시 넓힘: 쪼개졌던 행이 한 행으로 합쳐져야 한다
    core.scrollViewport(10);
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    const joined = core.scrollbackRow(0).?;
    try std.testing.expectEqual(@as(u21, 'a'), joined[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), joined[7].codepoint);
}

fn cellsText4(row: []const types.Cell) [4]u8 {
    var out: [4]u8 = .{ ' ', ' ', ' ', ' ' };
    for (row[0..@min(row.len, 4)], 0..) |cell, k| out[k] = @intCast(cell.codepoint);
    return out;
}

test "scrollback re-wrap keeps hard line boundaries separate and drops oldest rows past the cap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    core.screen.sb.cap = 4; // 작은 cap으로 드랍 검증
    try core.write("aaaa\r\nbb\r\ncccc\r\ndd\r\n1\r\n2"); // 4줄이 스크롤백(각각 hard)
    try std.testing.expectEqual(@as(usize, 4), core.scrollbackLen());

    try core.resize(2, 2); // 2칸: aaaa->aa|aa, bb->bb, cccc->cc|cc, dd->dd = 6행 > cap 4
    core.scrollViewport(10);
    try std.testing.expectEqual(@as(usize, 4), core.scrollbackLen()); // 오래된 2행 드랍
    // 남은 것은 최신 4행: cc, cc, dd 쪽이 보존되고 hard 경계(bb/cccc 사이 등)는 안 합쳐졌다.
    const last = core.scrollbackRow(3).?;
    try std.testing.expectEqual(@as(u21, 'd'), last[0].codepoint);
    try std.testing.expect(!core.scrollbackRowWrapped(3));
}

test "scrollback re-wrap is deferred until the scrollback is actually viewed" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("abcdefgh\r\n1\r\n2");
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    try core.resize(4, 2);
    // 아직 안 봤으니 ring은 옛 폭 그대로(지연) — 행 수 불변.
    try std.testing.expect(core.screen.sb.rewrap_pending);
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    core.scrollViewport(1); // 보는 순간 재-wrap
    try std.testing.expect(!core.screen.sb.rewrap_pending);
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
}

test "resize while scrolled back keeps the viewed scrollback row anchored (Ghostty tracked-pin semantics)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // 스크롤백 4행: aaaa / abcdefgh / cccc / dddd (모두 hard).
    try core.write("aaaa\r\nabcdefgh\r\ncccc\r\ndddd\r\n1\r\n2");
    try std.testing.expectEqual(@as(usize, 4), core.scrollbackLen());
    core.scrollViewport(3); // 뷰 최상단 = 스크롤백 행1("abcdefgh")
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(0)[1].codepoint);

    try core.resize(4, 2); // 좁힘: abcdefgh -> abcd|efgh. 보던 행("abcd...")이 그대로 보여야 한다.
    try std.testing.expect(core.view_offset > 0); // 바닥으로 안 튕김
    const top = core.viewportRow(0);
    try std.testing.expectEqual(@as(u21, 'a'), top[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), top[1].codepoint);

    try core.resize(8, 2); // 다시 넓힘(행 합쳐져 sb_count 감소): 여전히 같은 내용이 보인다.
    const top2 = core.viewportRow(0);
    try std.testing.expectEqual(@as(u21, 'a'), top2[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), top2[1].codepoint);
    try std.testing.expect(core.view_offset <= core.scrollbackLen()); // Ghostty 회귀 클래스(범위 초과) 방어
}

test "resize overflow pushed to scrollback keeps the scrolled view in place (scroll-lock)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("aa\r\nbb\r\ncc\r\ndd\r\nee\r\nff"); // 스크롤백 2(aa,bb) + 화면 cc,dd,ee,ff
    core.scrollViewport(2); // 맨 위(aa)를 본다
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try core.resize(4, 2); // 행 수 축소: 화면 위쪽이 스크롤백으로 밀린다(overflow push)
    // 보던 행(aa)이 여전히 뷰 최상단이어야 한다 — push마다 offset이 같이 올라갔어야(scroll-lock).
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
}

test "DECSCUSR (CSI Ps SP q) sets the cursor shape and blink" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape); // 기본 blink block
    try std.testing.expect(core.cursor_blink);
    try core.write("\x1b[5 q"); // 깜빡 bar(vim 삽입 모드가 흔히 씀)
    try std.testing.expectEqual(types.CursorShape.bar, core.cursor_shape);
    try std.testing.expect(core.cursor_blink);
    try core.write("\x1b[4 q"); // 고정 underline
    try std.testing.expectEqual(types.CursorShape.underline, core.cursor_shape);
    try std.testing.expect(!core.cursor_blink);
    try core.write("\x1b[0 q"); // 0 -> 터미널 기본(default_cursor_shape, 주입 없으면 깜빡 block)
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape);
    try std.testing.expect(core.snapshot().cursor_shape == .block);
    try core.write("\x1b[9 q"); // 모르는 값은 무시
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape);
}

// config `cursor.shape`가 코어 **기본** 모양으로 살아 있는지 고정한다. 회귀: `ResolvedCursor.shape`가 resolve만 되고
// 소비처가 없어 설정이 무동작이었다(cursor.blink와 같은 배선 누락 계열). 계약은 "config=기본값, DECSCUSR 1..6=앱
// override, DECSCUSR 0·RIS=기본으로 복귀" — 이 셋을 한 테스트에서 잠근다.
test "default cursor shape: config 기본값 + DECSCUSR override + 0/RIS 복귀" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    // ① 주입 즉시 반영(앱이 아직 아무것도 안 시켰으므로) — createTerm chokepoint가 첫 출력 전에 부르는 경로.
    core.setDefaultCursorShape(.bar);
    try std.testing.expectEqual(types.CursorShape.bar, core.cursor_shape);
    try std.testing.expectEqual(types.CursorShape.bar, core.default_cursor_shape);
    try std.testing.expect(!core.cursor_shape_overridden);

    // ② 앱 DECSCUSR가 이긴다(vim normal-mode block) — override 표시.
    try core.write("\x1b[2 q");
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape);
    try std.testing.expect(core.cursor_shape_overridden);

    // ③ override 중 config reload는 기본값만 갱신하고 화면은 안 건드린다(설정 바꿨다고 vim 커서가 튀지 않게).
    core.setDefaultCursorShape(.underline);
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape); // 라이브 커서 불변
    try std.testing.expectEqual(types.CursorShape.underline, core.default_cursor_shape); // 기본값만 갱신

    // ④ DECSCUSR 0 = 앱이 override를 거둬들임 → 사용자 config가 다시 보인다(옛 코드는 여기서 하드코딩 block이었다).
    try core.write("\x1b[0 q");
    try std.testing.expectEqual(types.CursorShape.underline, core.cursor_shape);
    try std.testing.expect(!core.cursor_shape_overridden);

    // ⑤ RIS(ESC c)도 공장 초기화 = 사용자 기본으로(override 중이었어도 해제).
    try core.write("\x1b[5 q"); // 앱이 다시 bar로 override
    try std.testing.expectEqual(types.CursorShape.bar, core.cursor_shape);
    try core.write("\x1bc");
    try std.testing.expectEqual(types.CursorShape.underline, core.cursor_shape);
    try std.testing.expect(!core.cursor_shape_overridden);
}

test "selection extracts text across soft-wrapped and hard rows (scrollback + active)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // "abcdef"(abcd|ef soft-wrap) + "hi" — abcd가 스크롤백으로 밀린 상태를 만든다.
    try core.write("abcdef\r\nhi\r\nx");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen()); // abcd, ef

    // 스크롤백 행0(abcd)부터 활성 행0(x 이전의 hi... 레이아웃: sb=[abcd,ef], 화면=[hi, x])
    core.scrollViewport(2); // 맨 위 — 뷰포트 [abcd, ef]
    core.selectionStart(0, 0); // abs 0 (abcd 시작)
    core.selectionExtend(1, 3); // abs 1 (ef 행 끝)
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    // soft-wrap 경계는 줄바꿈 없이 이어진다: "abcdef"
    try std.testing.expectEqualStrings("abcdef", text);

    // hard 경계를 포함한 선택: ef(abs1) ~ hi(abs2, 활성 행0)
    core.selectionStart(1, 0);
    core.scrollToBottom(); // 선택은 절대 좌표라 스크롤해도 유지
    core.selectionExtend(0, 3); // 바닥 뷰포트 행0 = abs2(hi)
    const text2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("ef\nhi", text2);
}

test "keycap emoji is stored losslessly in grapheme_store so copied bytes match (HG2b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // 2️⃣ = '2' + VS16(FE0F) + U+20E3. 셋이 grapheme_store에 base 뒤 [VS16, U+20E3]로 온전히 담긴다 —
    // 단일 combining 슬롯 시절 VS16이 U+20E3에 덮여 사라지던 문제가 사라져, 복사가 재주입 hack 없이
    // store 본체에서 온전한 키캡 시퀀스를 낸다(이전엔 selection이 VS16을 재주입으로 때웠다).
    try core.write("\x32\xef\xb8\x8f\xe2\x83\xa3");
    try std.testing.expectEqual(@as(u21, 0x32), core.screen.cells[0].codepoint);
    try std.testing.expect(core.screen.cells[0].grapheme_id != 0);
    try expectCluster(&core, core.screen.cells[0].grapheme_id, &.{ 0xFE0F, 0x20E3 });

    core.selectionStart(0, 0);
    core.selectionExtend(0, 3);
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    // 복사 바이트 = base + VS16 + U+20E3 — 화면 컬러 키캡과 일치('2'+U+20E3만 복사되어 깨지지 않음).
    try std.testing.expectEqualStrings("\x32\xef\xb8\x8f\xe2\x83\xa3", text);
}

test "selection extracts an NFD Hangul cluster losslessly (multi-codepoint grapheme body)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();
    // NFD '한' = 초성 U+1112 + 중성 U+1161 + 종성 U+11AB. 한 셀에 묶이고 중성·종성은 grapheme_store에
    // 담긴다 — 복사 바이트가 원본 자모 3개를 모두 보존해야(잘림 금지, 설계 §3.2) 붙여넣는 앱에서
    // 음절이 깨지지 않는다(combining 그림자만 복사하면 종성이 사라진다).
    try core.write("\u{1112}\u{1161}\u{11AB}");
    core.selectionStart(0, 0);
    core.selectionExtend(0, 1);
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("\u{1112}\u{1161}\u{11AB}", text);
}

test "selection span clips to the viewport and follows scrolling" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // sb=[a,b], 화면=[c,d]
    core.selectionStart(0, 0); // abs 2(c)
    core.selectionExtend(1, 1); // abs 3(d)
    const span = core.selectionViewportSpan().?;
    try std.testing.expectEqual(@as(u16, 0), span.start.row);
    try std.testing.expectEqual(@as(u16, 1), span.end.row);

    core.scrollViewport(2); // 위로 — 선택(c,d)은 화면 밖
    try std.testing.expect(core.selectionViewportSpan() == null);
    core.scrollViewport(-1); // 한 줄 내림 — 뷰포트 [b, c]: 선택 시작(c)이 행1에 보인다
    const span2 = core.selectionViewportSpan().?;
    try std.testing.expectEqual(@as(u16, 1), span2.start.row);
    try std.testing.expectEqual(@as(u16, 1), span2.end.row); // d는 아래로 클립
    try std.testing.expectEqual(@as(u16, 3), span2.end.col);
}

test "block selection extracts a rectangle column-slice per row (Option+drag)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\nghijkl\r\nmnopqr"); // 3행, 각 6글자(cols=8라 wrap 없음)

    // 블록 선택 cols 1..3 × rows 0..2 → 각 행의 [1,3] 열만, 행마다 개행(소프트랩 무관).
    core.selectionStart(0, 1);
    core.setSelectionBlock(true);
    core.selectionExtend(2, 3);
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("bcd\nhij\nnop", text);

    // anchor col > head col이어도 min/max로 같은 사각형.
    core.selectionStart(0, 3);
    core.setSelectionBlock(true);
    core.selectionExtend(2, 1);
    const text2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("bcd\nhij\nnop", text2);

    // hi가 내용보다 넓으면 각 행 뒤 빈칸을 trim(패딩 제외 — 선형 추출과 같은 규칙).
    core.selectionStart(0, 1);
    core.setSelectionBlock(true);
    core.selectionExtend(2, 7);
    const text3 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text3);
    try std.testing.expectEqualStrings("bcdef\nhijkl\nnopqr", text3);
}

test "block selection span carries block flag + lo/hi; selectionStart resets to linear" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\nghijkl\r\nmnopqr");

    core.selectionStart(0, 3);
    core.setSelectionBlock(true);
    core.selectionExtend(2, 1);
    const span = core.selectionViewportSpan().?;
    try std.testing.expect(span.block);
    try std.testing.expectEqual(@as(u16, 0), span.start.row);
    try std.testing.expectEqual(@as(u16, 2), span.end.row);
    try std.testing.expectEqual(@as(u16, 1), span.start.col); // lo
    try std.testing.expectEqual(@as(u16, 3), span.end.col); // hi

    // 새 selectionStart는 선형으로 리셋(이전 블록 모드가 새 선택에 안 샌다).
    core.selectionStart(0, 0);
    core.selectionExtend(0, 2);
    const span2 = core.selectionViewportSpan().?;
    try std.testing.expect(!span2.block);

    // setSelectionBlock은 anchor 없으면 무시(선택 없는데 블록 토글은 무효).
    core.selectionClear();
    core.setSelectionBlock(true);
    try std.testing.expect(!core.selection_block);
}

test "selectAll/selectWordAt/selectLineAt이 블록 모드를 리셋한다(Option+드래그 뒤 누수 방지)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\nghijkl\r\nmnopqr");

    // selectAll: 블록 켠 뒤 ⌘A는 선형 전체여야 한다(직사각형 truncate 누수 방지 — 리뷰 발견 #1).
    core.selectionStart(0, 1);
    core.setSelectionBlock(true);
    core.selectionExtend(2, 3);
    core.selectAll();
    try std.testing.expect(!core.selection_block);
    const all = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(all);
    try std.testing.expectEqualStrings("abcdef\nghijkl\nmnopqr", all); // 직사각형이 아니라 전체

    // selectWordAt(더블클릭)·selectLineAt(트리플클릭)도 새 선택이라 선형으로 리셋.
    core.selectionStart(0, 1);
    core.setSelectionBlock(true);
    core.selectWordAt(0, 0, ""); // 'a'..'f' run
    try std.testing.expect(!core.selection_block);

    core.selectionStart(0, 1);
    core.setSelectionBlock(true);
    core.selectLineAt(1);
    try std.testing.expect(!core.selection_block);
}

test "selection survives new output until eviction shifts it off the ring" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.screen.sb.cap = 2;
    try core.write("a\r\nb\r\nc"); // sb=[a], 화면=[b,c]
    core.selectionStart(0, 0);
    core.selectionExtend(0, 0); // abs 0 = "a"(스크롤백 첫 행 — 화면 첫 행 b가 아님? 뷰포트 행0=b... )
    // 주: 바닥 뷰포트 행0 = abs sb_count(1)=b. 위 선택은 b를 가리킨다.
    try core.write("\r\nd"); // 스크롤 1회: sb=[a,b] (cap 2, eviction 없음) — 선택 abs는 불변(내용 b 유지)
    const t1 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(t1);
    try std.testing.expectEqualStrings("b", t1);
    try core.write("\r\ne"); // 또 스크롤: cap 도달, a가 evict — 선택(b)은 -1 보정돼 유지
    const t2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(t2);
    try std.testing.expectEqualStrings("b", t2);
    try core.write("\r\nf"); // b도 evict — 선택이 ring 밖으로: 해제
    try std.testing.expect(core.selection_anchor == null);
}

test "double-click selects the word run, extending across a soft-wrap boundary" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ab cdefghij kl"); // 8칸: "ab cdefg"|"hij kl" — 단어 cdefghij가 wrap을 넘는다
    try std.testing.expect(core.screen.wrapped[0]);

    core.selectWordAt(0, 4, ""); // 행0 col4('e') 더블클릭
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("cdefghij", text); // wrap 경계 너머까지 한 단어

    core.selectWordAt(1, 4, ""); // 행1 col4 ('k') — 같은 행 안 단어
    const text2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("kl", text2);

    core.selectWordAt(0, 2, ""); // 공백 더블클릭 -> 해제
    try std.testing.expect(core.selection_anchor == null);
}

test "double-click with word-separators splits at separator chars; URL detection unaffected (F2-8)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 40, .rows = 2 });
    defer core.deinit();
    try core.write("https://example.com/a /usr/bin");

    // 구분자 없음(기본 ""): 비공백 run 전체 — "https://example.com/a"가 한 단어.
    core.selectWordAt(0, 4, "");
    const w0 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(w0);
    try std.testing.expectEqualStrings("https://example.com/a", w0);

    // 구분자 "/:"(슬래시·콜론): 같은 클릭이 토큰을 잘게 — col4는 "https"(h t t p s, col0~4) 안.
    core.selectWordAt(0, 4, "/:");
    const w1 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(w1);
    try std.testing.expectEqualStrings("https", w1);

    // 구분자 클릭(":" 위 col5) → 그 1칸만 선택(구분자=토큰).
    core.selectWordAt(0, 5, "/:");
    const w2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(w2);
    try std.testing.expectEqualStrings(":", w2);

    // 두 번째 토큰 "/usr/bin"(col22~)에서 "/"를 구분자로 두면 "usr"만(col23~25).
    core.selectWordAt(0, 23, "/:");
    const w3 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(w3);
    try std.testing.expectEqualStrings("usr", w3);

    // **URL 감지는 구분자 무시**: wordBoundsAt(공백만)이라 wordIsUrl이 전체 URL을 본다(col4=h).
    try std.testing.expect(selection.wordIsUrl(&core, 0, 4, selection.link_scopes_full));
}

test "triple-click selects the whole logical line including wrapped rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\nxy"); // abcd|ef(논리 한 줄) + xy
    core.selectLineAt(1); // wrap된 두 번째 행을 트리플클릭해도 논리 줄 전체
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("abcdef", text);
}

test "encodePaste normalizes newlines and wraps with bracketed paste when DECSET 2004 is on" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // 기본(비-bracketed): \r\n/\n -> \r 정규화만.
    const plain = try core.encodePaste(std.testing.allocator, "a\r\nb\nc");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("a\rb\rc", plain);

    try core.write("\x1b[?2004h"); // zsh/claude가 켜는 bracketed paste
    const wrapped_paste = try core.encodePaste(std.testing.allocator, "ls\n");
    defer std.testing.allocator.free(wrapped_paste);
    try std.testing.expectEqualStrings("\x1b[200~ls\r\x1b[201~", wrapped_paste);

    try core.write("\x1b[?2004l");
    try std.testing.expect(!core.bracketed_paste);
}

test "encodePaste strips ESC from the body to prevent bracketed-paste injection" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?2004h"); // bracketed paste on
    // 악성 클립보드: 본문에 ESC[201~를 심어 괄호를 일찍 닫고 명령을 주입하려 함.
    const malicious = "x\x1b[201~\rrm -rf ~\r";
    const encoded = try core.encodePaste(std.testing.allocator, malicious);
    defer std.testing.allocator.free(encoded);
    // 본문의 ESC가 공백이 돼 인젝션 시퀀스가 무력화되고, 진짜 종료 괄호는 끝에 하나뿐이어야 한다.
    try std.testing.expectEqualStrings("\x1b[200~x [201~\rrm -rf ~\r\x1b[201~", encoded);
    // 본문 안에는 ESC가 없다(시작/끝 괄호의 ESC 2개만).
    var esc_count: usize = 0;
    for (encoded) |b| {
        if (b == 0x1b) esc_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), esc_count);
}

test "encodePaste strips the full xterm control-byte set (NUL/BS/DEL/VINTR 등), not just ESC" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // 위험 제어 바이트가 전부 공백으로 치환된다(xterm/Ghostty strip 목록). 탭·정상 글자는 보존, 개행은 \r.
    const dangerous = "a\x00b\x08c\x7fd\x03e\x1af\tg\nh";
    const encoded = try core.encodePaste(std.testing.allocator, dangerous);
    defer std.testing.allocator.free(encoded);
    // NUL/BS/DEL/Ctrl+C/Ctrl+Z → 공백, \t 보존, \n → \r.
    try std.testing.expectEqualStrings("a b c d e f\tg\rh", encoded);
}

test "pasteNeedsConfirmation: 개행/인젝션 감지 + bracketed-safe 게이트 (Ghostty 동형)" {
    // 이 테스트가 증명하는 것: paste protection 게이트가 (1) protection 꺼짐이면 무조건 통과, (2) 비-bracketed
    // 개행 붙여넣기는 확인 요구, (3) bracketed + bracketed-safe면 개행이 있어도 확인 생략(괄호가 감쌈),
    // (4) 단 bracketed여도 본문 종료 마커(ESC[201~)는 항상 확인(조기 종료 인젝션), (5) 개행 없는 평문은 안전.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();

    // 비-bracketed 기본(2004 off):
    try std.testing.expect(!core.pasteNeedsConfirmation("echo hi", true, true)); // 개행 없음 → 안전
    try std.testing.expect(core.pasteNeedsConfirmation("echo hi\nrm -rf ~", true, true)); // \n → 확인
    try std.testing.expect(core.pasteNeedsConfirmation("a\rb", true, true)); // \r도 실행 트리거 → 확인
    try std.testing.expect(!core.pasteNeedsConfirmation("echo hi\nrm", false, true)); // protection 꺼짐 → 통과

    // bracketed paste on(zsh/claude가 켬):
    try core.write("\x1b[?2004h");
    try std.testing.expect(core.bracketed_paste);
    // bracketed-safe=true(기본): 개행이 있어도 괄호가 감싸 안전 → 확인 생략.
    try std.testing.expect(!core.pasteNeedsConfirmation("echo hi\nrm -rf ~", true, true));
    // 단 본문 종료 마커는 bracketed여도 항상 확인(괄호 조기 종료 인젝션).
    try std.testing.expect(core.pasteNeedsConfirmation("x\x1b[201~rm", true, true));
    // bracketed-safe=false: bracketed여도 개행 검사 → 확인.
    try std.testing.expect(core.pasteNeedsConfirmation("echo hi\nrm", true, false));
}

test "extractUrlAt finds an http(s) URL in the clicked word, across soft-wrap, trimming punctuation" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();
    try core.write("see (https://a.bc/dpath)."); // 12칸 wrap: "see (https:/"|"/a.bc/dpath)"|"."
    try std.testing.expect(core.screen.wrapped[0]);

    // wrap된 URL의 두 번째 행을 Cmd+클릭해도 전체 URL이 나오고, 끝 ")."는 다듬어진다.
    const url = (try core.extractUrlAt(std.testing.allocator, 1, 3, selection.link_scopes_full)).?;
    defer std.testing.allocator.free(url.text);
    try std.testing.expectEqualStrings("https://a.bc/dpath", url.text);

    // URL이 아닌 단어는 null.
    try std.testing.expect((try core.extractUrlAt(std.testing.allocator, 0, 0, selection.link_scopes_full)) == null);
    // 공백도 null.
    try std.testing.expect((try core.extractUrlAt(std.testing.allocator, 0, 3, selection.link_scopes_full)) == null);
}

test "extractUrlAt stops at a background-colored (bce) space — URL not swallowing trailing text" {
    // 회귀: 상태줄/프롬프트/erase가 배경색(SGR 44)으로 칠한 공백은 codepoint=' '이지만 background≠default라
    // isBlankCell이 false다. 단어 경계가 그걸 공백으로 안 보면 URL 뒤 " foo"가 통째로 빨려들어 "https://a.bc/d foo"가
    // 브라우저로 열린다. 경계는 배경 무관 공백(isBoundarySpace)을 봐야 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 24, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[44mhttps://a.bc/d foo\x1b[0m"); // 파란 배경: URL·공백·foo 모두 background=indexed 4
    // 공백 셀이 실제로 비기본 배경인지 확인(가드가 의미 있으려면 isBlankCell이 false여야 한다).
    try std.testing.expectEqual(types.Color{ .indexed = 4 }, core.screen.cells[core.index(0, 14)].style.background);

    const url = (try core.extractUrlAt(std.testing.allocator, 0, 2, selection.link_scopes_full)).?; // URL 안 클릭
    defer std.testing.allocator.free(url.text);
    try std.testing.expectEqualStrings("https://a.bc/d", url.text); // 공백에서 끊겨 foo가 안 붙는다
    // 색칠된 공백 위 클릭은 선택/URL 없음(배경색 무관 — 일반 공백과 동일).
    try std.testing.expect((try core.extractUrlAt(std.testing.allocator, 0, 14, selection.link_scopes_full)) == null);
}

// **밑줄 보이는 곳 = 열리는 곳.** `linkScopesForTerm`의 doc이 선언한 불변식인데, 지금까지 스코프 수준에서만
// 지켜지고 존재 수준에서는 비어 있었다 — hover는 분류만 하고 클릭만 stat했다. 이 테스트가 그 나머지 절반을
// 고정한다: **같은 좌표에서 두 함수의 답이 갈리면 실패**다.
const nl = [_]u8{ 0x0D, 0x0A };

test "hover와 클릭이 같은 답을 낸다 — 존재검증까지" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 80, .rows = 6 });
    defer core.deinit();
    const full = selection.link_scopes_full;

    // **절대 경로로 쓴다** — cwd(OSC 7) 없이도 resolve되므로 이 테스트가 셸 상태에 안 매인다.
    const existing = if (@import("builtin").os.tag == .windows) "C:/Windows" else "/tmp";
    const missing = if (@import("builtin").os.tag == .windows) "C:/nope-9e1f-maru" else "/nope-9e1f-maru";

    try core.write("a ");
    try core.write(existing);
    try core.write(" here" ++ nl);
    try core.write("b ");
    try core.write(missing);
    try core.write(" here" ++ nl);
    try core.write("c https://example.com here" ++ nl);

    const cases = [_]struct { row: u16, col: u16, want: bool, note: []const u8 }{
        .{ .row = 0, .col = 2, .want = true, .note = "실재 디렉터리" },
        .{ .row = 1, .col = 2, .want = false, .note = "없는 경로 — 밑줄도 뜨면 안 된다" },
        .{ .row = 2, .col = 2, .want = true, .note = "URL — stat 없이 통과" },
    };
    for (cases) |c| {
        const hover = (try core.openableLinkAnchorAt(allocator, c.row, c.col, full)) != null;
        const click = blk: {
            const ext = (try core.extractUrlAt(allocator, c.row, c.col, full)) orelse break :blk false;
            allocator.free(ext.text);
            break :blk true;
        };
        if (hover != click) {
            std.debug.print("hover({})와 click({})이 갈렸다: {s}", .{ hover, click, c.note });
            return error.TestUnexpectedResult;
        }
        if (hover != c.want) {
            std.debug.print("기대와 다르다({s}): got={} want={}", .{ c.note, hover, c.want });
            return error.TestUnexpectedResult;
        }
    }
}

// **비-ASCII 이름이 든 경로도 열린다.** Windows CRT의 `_access`는 바이트 경로를 UTF-8이 아니라 ANSI
// 코드페이지로 읽어, ACP=949인 기계에서 `한글`·`日本`·`café`·이모지 디렉터리를 전부 "없음"으로 냈다
// (Win32 UTF-16으로는 전부 실재). 그래서 그 경로는 클릭해도 안 열리고 밑줄도 안 떴다. `pathExists`가
// OS별로 갈라 그것을 닫았고, 이 테스트가 되돌아오는 것을 막는다. POSIX에서는 늘 성립하던 것이라
// **두 OS 모두에서 도는 것**이 요점이다 — Windows 러너가 없으므로 macOS/Linux CI가 이 계약의 절반을 지킨다.
// **공백 든 경로.** 토큰 모델이 공백을 경계로 보므로 `C:\Program Files\x.txt`는 예전에 `C:\Program`에서
// 잘렸고, 잘린 것은 존재 게이트가 죽여 **전혀** 안 잡혔다. `openableLinkAt`이 존재로 확장해 그것을 닫는다 —
// 이 테스트가 ⑴ 확장이 실제로 되는가 ⑵ 산문으로 새지 않는가 ⑶ **밑줄 범위가 경로 전체를 덮는가**를 고정한다.
// 두 OS 모두에서 돈다(임시 디렉터리를 실제로 만든다).
test "공백 든 경로가 잡히고 밑줄이 경로 전체를 덮는다" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "Program Files", .default_dir);
    var sub = try tmp.dir.openDir(io, "Program Files", .{});
    defer sub.close(io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const raw = path_buf[0..try sub.realPath(io, &path_buf)];
    const dir = if (std.mem.startsWith(u8, raw, "\\\\?\\")) raw[4..] else raw;
    // 화면에는 `/` 철자로 띄운다 — 두 OS에서 같은 문자열을 쓰기 위해서다(Windows도 `/`를 받는다).
    const shown = try allocator.dupe(u8, dir);
    defer allocator.free(shown);
    for (shown) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }

    var core = try TerminalCore.init(allocator, .{ .cols = 240, .rows = 4 });
    defer core.deinit();
    try core.write("see ");
    try core.write(shown);
    try core.write(" and more words");

    const full = selection.link_scopes_full;
    // ⑴ 확장이 된다 — 경로 안(col 6)에서 열 대상이 **공백 뒤까지** 나온다.
    const link = (try core.openableLinkAt(allocator, 0, 6, full)) orelse {
        std.debug.print("공백 경로가 안 잡혔다: {s}\n", .{shown});
        return error.TestUnexpectedResult;
    };
    defer allocator.free(link.text);
    if (std.mem.indexOf(u8, link.text, "Program Files") == null) {
        std.debug.print("확장이 공백 앞에서 끊겼다: {s}\n", .{link.text});
        return error.TestUnexpectedResult;
    }
    // ⑵ 산문으로 새지 않는다 — 뒤의 `and more words`는 실재하지 않으므로 포함되면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, link.text, "and") == null);

    // ⑶ 밑줄 범위가 경로 끝(공백 뒤 세그먼트)까지 덮는다. 토큰만 덮으면 "밑줄 밖을 눌러야 열리는" 상태다.
    const bounds = link.bounds orelse return error.TestUnexpectedResult;
    const token_end_col = 4 + std.mem.indexOfScalar(u8, shown, ' ').?; // "see " 4칸 + 공백 위치
    try std.testing.expect(bounds.end.col > token_end_col);

    // ⑷ hover도 같은 끝을 실어 준다(밑줄과 열림이 갈리지 않는다).
    const hover = (try core.openableLinkAnchorAt(allocator, 0, 6, full)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(bounds.end.col, (hover.end orelse return error.TestUnexpectedResult).col);
}

test "존재검증은 비-ASCII 이름이 든 경로를 놓치지 않는다" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const names = [_][]const u8{ "maru-ascii-9e1f", "maru-한글-9e1f", "maru-日本-9e1f", "maru-café-9e1f" };
    for (names) |name| {
        try tmp.dir.createDir(io, name, .default_dir);
        var sub = try tmp.dir.openDir(io, name, .{});
        defer sub.close(io);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const raw = path_buf[0..try sub.realPath(io, &path_buf)];
        // Windows realpath는 `\\?\C:\…` 확장 접두를 줄 수 있는데, 그 모양은 감지가 UNC로 보고 거부한다
        // (`isDetectableAbsoluteFor`). 화면에 뜨는 형태는 접두 없는 경로이므로 그것으로 맞춘다.
        const abs = if (std.mem.startsWith(u8, raw, "\\\\?\\")) raw[4..] else raw;

        var core = try TerminalCore.init(allocator, .{ .cols = 240, .rows = 4 });
        defer core.deinit();
        try core.write("go ");
        try core.write(abs);
        try core.write(" ok");

        const hover = (try core.openableLinkAnchorAt(allocator, 0, 4, selection.link_scopes_full)) != null;
        const click = blk: {
            const ext = (try core.extractUrlAt(allocator, 0, 4, selection.link_scopes_full)) orelse break :blk false;
            allocator.free(ext.text);
            break :blk true;
        };
        if (!hover or !click) {
            std.debug.print("실재하는데 열리지 않는다: {s} (hover={} click={})\n", .{ abs, hover, click });
            return error.TestUnexpectedResult;
        }
    }
}

test "urlAnchorAt + urlSpanAtAbs project the hovered URL word, following content and rejecting non-URLs" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();
    try core.write("go https://a.bc/d now");
    const anchor = core.urlAnchorAt(0, 5, selection.link_scopes_full).?; // URL 위 → 단어 시작 절대 좌표
    const span = core.urlSpanAtAbs(anchor).?;
    try std.testing.expectEqual(@as(u16, 0), span.start.row);
    try std.testing.expectEqual(@as(u16, 3), span.start.col); // "https://..." 단어 시작
    try std.testing.expect(core.urlAnchorAt(0, 0, selection.link_scopes_full) == null); // "go"
    try std.testing.expect(selection.wordIsUrl(&core, 0, 5, selection.link_scopes_full)); // 할당 없는 판정도 같은 결과
    try std.testing.expect(!selection.wordIsUrl(&core, 0, 0, selection.link_scopes_full));
}

test "linkSpanInWord keeps balanced trailing parens but trims prose punctuation" {
    // Wikipedia식: 끝 ')'가 열린 '('와 균형이면 URL의 일부.
    const a = selection.linkSpanInWord("https://en.wikipedia.org/wiki/Foo_(bar)", selection.link_scopes_web).?;
    try std.testing.expectEqualStrings("https://en.wikipedia.org/wiki/Foo_(bar)", "https://en.wikipedia.org/wiki/Foo_(bar)"[a.start..a.end]);
    try std.testing.expectEqual(selection.LinkKind.url, a.kind);
    // 산문 속: 균형 안 맞는 끝 ')'와 '.'은 다듬는다.
    const b = selection.linkSpanInWord("(https://a.bc/d).", selection.link_scopes_web).?;
    try std.testing.expectEqualStrings("https://a.bc/d", "(https://a.bc/d)."[b.start..b.end]);
}

test "linkSpanInWord classifies extra schemes and file paths, with scope gating" {
    const full = selection.link_scopes_full;
    const Case = struct { in: []const u8, want: []const u8, kind: selection.LinkKind };
    const cases = [_]Case{
        // 추가 스킴(extra_schemes). "dot.http://x"는 스킴부터.
        .{ .in = "dot.http://example.com", .want = "http://example.com", .kind = .url },
        .{ .in = "ftp://example.com", .want = "ftp://example.com", .kind = .url },
        .{ .in = "mailto:a@b.com", .want = "mailto:a@b.com", .kind = .url },
        .{ .in = "ssh://1.2.3.4", .want = "ssh://1.2.3.4", .kind = .url },
        .{ .in = "file:///etc/hosts", .want = "file:///etc/hosts", .kind = .url },
        // 절대/홈/dot-relative/bare-relative 경로.
        .{ .in = "/Users/me/a.py", .want = "/Users/me/a.py", .kind = .file_path },
        .{ .in = "~/.config/maru/config", .want = "~/.config/maru/config", .kind = .file_path },
        .{ .in = "./src/main.zig", .want = "./src/main.zig", .kind = .file_path },
        .{ .in = "../lib/y.rb", .want = "../lib/y.rb", .kind = .file_path },
        .{ .in = "src/config/url.zig", .want = "src/config/url.zig", .kind = .file_path },
        .{ .in = ".config/maru/config", .want = ".config/maru/config", .kind = .file_path },
        // :line:col 접미 보존, 콤마/매달린 콜론 다듬기.
        .{ .in = "app/folder/file.rb:1", .want = "app/folder/file.rb:1", .kind = .file_path },
        .{ .in = "lib/x/terminal.zig:42:10", .want = "lib/x/terminal.zig:42:10", .kind = .file_path },
        .{ .in = "src/foo.c,baz.txt", .want = "src/foo.c", .kind = .file_path },
        .{ .in = "./Downloads:", .want = "./Downloads", .kind = .file_path },
        // IPv6 권위부·대괄호 — 닫는 ']'는 균형이면 보존(trimUrlTail 대괄호 균형, 적대적 검증 발견).
        .{ .in = "http://[::1]", .want = "http://[::1]", .kind = .url },
        .{ .in = "https://[2001:db8::1]:8080/path", .want = "https://[2001:db8::1]:8080/path", .kind = .url },
        .{ .in = "https://example.com/[foo]", .want = "https://example.com/[foo]", .kind = .url },
        // 스킴 변종(전체 8종) + 쿼리/프래그먼트.
        .{ .in = "git://example.com/repo.git", .want = "git://example.com/repo.git", .kind = .url },
        .{ .in = "tel:+12125551234", .want = "tel:+12125551234", .kind = .url },
        .{ .in = "news:comp.lang.c", .want = "news:comp.lang.c", .kind = .url },
        .{ .in = "magnet:?xt=urn:btih:abc", .want = "magnet:?xt=urn:btih:abc", .kind = .url },
        .{ .in = "https://x.y/p?a=1&b=2", .want = "https://x.y/p?a=1&b=2", .kind = .url },
        .{ .in = "https://x.y/p#frag", .want = "https://x.y/p#frag", .kind = .url },
        // 파일 경로 변종: 숫자 디렉토리, 점 시작 bare, 절대경로 안 균형 대괄호, 콜론 뒤 비숫자(span 보존).
        .{ .in = "2024/report.txt", .want = "2024/report.txt", .kind = .file_path },
        .{ .in = "..foo/bar.zig", .want = "..foo/bar.zig", .kind = .file_path },
        .{ .in = "/var/log/[id].txt", .want = "/var/log/[id].txt", .kind = .file_path },
        .{ .in = "src/foo.zig:abc", .want = "src/foo.zig:abc", .kind = .file_path },
        // 산문 trailing 다듬기(경로 끝 마침표).
        .{ .in = "see/notes.md.", .want = "see/notes.md", .kind = .file_path },
        // span 밖 U+2026: 스킴 앞(앞 텍스트만 잘림)·콤마 다음(다음 토큰)은 링크 본문과 무관 — 온전한 링크는 그대로.
        .{ .in = "…https://example.com/page", .want = "https://example.com/page", .kind = .url },
        .{ .in = "src/a.zig,…", .want = "src/a.zig", .kind = .file_path },
    };
    for (cases) |c| {
        const span = selection.linkSpanInWord(c.in, full) orelse {
            std.debug.print("linkSpanInWord no match for: {s}\n", .{c.in});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(c.want, c.in[span.start..span.end]);
        try std.testing.expectEqual(c.kind, span.kind);
    }

    // no-match: 이중슬래시·점 없는 bare·$숫자·mid-word ~·본문 없는 스킴 + 대소문자 스킴·괄호 감싼 경로·빈/단일/비경로.
    const no_match = [_][]const u8{
        "//foo", "foo/bar", "input/output", "$10/bar", "foo~/bar.txt", "https://",
        "HTTP://x.y", // 스킴 대소문자 구분(소문자만) — RFC는 무관하나 셸 출력은 사실상 소문자
        "File://x", // 추가 스킴도 소문자만
        "https://example.com/full/…", // 말줄임된 휴리스틱 URL은 원본 복원 불가 — OSC 8이 있으면 그 경로가 우선
        "src/config/very….zig", // 말줄임된 휴리스틱 파일 경로도 열지 않는다
        "ftp://", "mailto:", // 추가 스킴 본문 없음(스킴만)
        "(/etc/hosts)", "[/etc/hosts]", // 괄호/대괄호로 감싸 토큰 시작이 경로 prefix가 아님
        "", "a", ".", "..", "~", "foobar", // 빈/단일/슬래시 없는 비경로
    };
    for (no_match) |w| {
        if (selection.linkSpanInWord(w, full) != null) {
            std.debug.print("linkSpanInWord unexpectedly matched: {s}\n", .{w});
            return error.TestUnexpectedResult;
        }
    }

    // **역슬래시 상대 경로**(W5.5) — 이 단언은 **제품 함수를 직접 몬다**. 규칙 자체의 전수 검증은
    // `path_shape.detectableRelativePrefixFor`가 두 OS 갈래로 하고(거기가 단일 출처), 여기서는 그것이
    // `linkSpanInWord`의 scope 태그까지 이어지는지를 본다.
    //
    // 감지는 **호스트 OS 기준**이라(절대 갈래와 같다) 단언을 호스트로 가른다. macOS에서 `.\x`가 안 잡히는
    // 것은 버그가 아니라 계약이다 — 거기서 그 토큰은 하위 경로가 아니라 그 이름의 파일 하나다.
    {
        const win_rel = [_][]const u8{ ".\\src\\main.zig", "..\\lib\\y.rb", "~\\notes.md", ".\\build" };
        for (win_rel) |w| {
            const got = selection.linkSpanInWord(w, full);
            if (@import("builtin").os.tag == .windows) {
                if (got == null) {
                    std.debug.print("Windows에서 역슬래시 상대가 안 잡혔다: {s}\n", .{w});
                    return error.TestUnexpectedResult;
                }
                try std.testing.expectEqual(selection.LinkKind.file_path, got.?.kind);
                try std.testing.expectEqualStrings(w, w[got.?.start..got.?.end]);
            } else if (got != null) {
                std.debug.print("비-Windows에서 역슬래시 상대가 잡혔다: {s}\n", .{w});
                return error.TestUnexpectedResult;
            }
        }
        // 정규식 조각은 **어느 호스트에서도** 링크가 아니다.
        for ([_][]const u8{ ".\\d+", ".\\s*", ".\\d{2,4}", ".\\n" }) |w| {
            if (selection.linkSpanInWord(w, full) != null) {
                std.debug.print("정규식 조각이 링크로 잡혔다: {s}\n", .{w});
                return error.TestUnexpectedResult;
            }
        }
    }

    // scope 게이팅: web만이면 경로·추가 스킴은 무시하고 http(s)만 잡는다(이전 동작 회귀 0).
    const web = selection.link_scopes_web;
    try std.testing.expect(selection.linkSpanInWord("/Users/me/a.py", web) == null);
    try std.testing.expect(selection.linkSpanInWord("~/x.txt", web) == null);
    try std.testing.expect(selection.linkSpanInWord("src/foo.zig", web) == null);
    try std.testing.expect(selection.linkSpanInWord("ftp://x.y", web) == null);
    try std.testing.expect(selection.linkSpanInWord("https://x.y", web) != null);
    // osc8-only(none): 자동 감지는 전부 꺼진다(OSC 8 명시 링크만 — 그건 호출자 cellLinkAt가 따로 처리).
    try std.testing.expect(selection.linkSpanInWord("https://x.y", selection.link_scopes_none) == null);

    // scope 비트 독립성(적대적 검증 발견): web 비트만 빠지면 나머지가 다 켜져도 http(s) 미감지,
    // 경로 비트가 전무하면 경로 미감지, extra_schemes 없으면 추가 스킴 미감지.
    try std.testing.expect(selection.linkSpanInWord("https://x.y", .{ .extra_schemes = true, .absolute_path = true, .home_path = true, .dot_relative = true, .bare_relative = true }) == null);
    try std.testing.expect(selection.linkSpanInWord("/abs/a.py", selection.link_scopes_web) == null);
    try std.testing.expect(selection.linkSpanInWord("ftp://x.y", selection.link_scopes_web) == null);

    // 엣지: 디렉토리 prefix만("/", "./", "~/", "../")은 현재 그 prefix로 match된다(존재하면 Finder로 열림 — 무해하나
    // 의도된 동작은 아님; 동작 변경은 별도 결정). 현재 동작을 회귀 가드로 고정한다.
    try std.testing.expect(selection.linkSpanInWord("/", full).?.kind == .file_path);
    try std.testing.expect(selection.linkSpanInWord("./", full).?.kind == .file_path);
    try std.testing.expect(selection.linkSpanInWord("~/", full).?.kind == .file_path);
    try std.testing.expect(selection.linkSpanInWord("../", full).?.kind == .file_path);
}

// 원격(host-backed) 세션은 client의 core가 빈 placeholder라 링크 감지가 host 쪽에서 일어나야 한다
// (docs/link-detection.md §원격(host-backed) 세션). host가 방출할 span 목록을 만드는 collectViewportLinks가
// (1) 로컬 hover와 같은 분류기를 쓰고, (2) 밑줄 범위를 토큰 전체로 잡고, (3) span마다 client가 자기 config로
// 거를 수 있는 scope 태그를 실어 주는지 고정한다. 이게 어긋나면 원격에서 밑줄이 안 뜨거나(회귀 재발) 엉뚱한
// 범위에 밑줄이 그어진다.
test "collectViewportLinks: 화면 링크를 종류·scope 태그와 함께 모은다" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 40, .rows = 6 });
    defer core.deinit();
    var out: std.ArrayList(selection.ViewportLink) = .empty;
    defer out.deinit(allocator);

    try core.write("go https://example.com/page now\r\n"); // web 스킴
    try core.write("see src/main.zig here\r\n"); // bare-relative 경로
    try core.write("cfg ~/.config/maru/config\r\n"); // home 경로
    try core.write("plain words only\r\n"); // 링크 없음
    try selection.collectViewportLinks(&core, allocator, selection.link_scopes_full, &out);

    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    // 밑줄 범위는 토큰 전체(로컬 urlSpanAtAbs와 같은 규칙) — "https://example.com/page"는 row0 col3..col26.
    try std.testing.expectEqual(@as(u16, 0), out.items[0].span.start.row);
    try std.testing.expectEqual(@as(u16, 3), out.items[0].span.start.col);
    try std.testing.expectEqual(@as(u16, 26), out.items[0].span.end.col);
    try std.testing.expectEqual(selection.LinkKind.url, out.items[0].kind);
    try std.testing.expectEqual(selection.LinkScope.web, out.items[0].scope);
    try std.testing.expectEqual(selection.LinkKind.file_path, out.items[1].kind);
    try std.testing.expectEqual(selection.LinkScope.bare_relative, out.items[1].scope);
    try std.testing.expectEqual(selection.LinkScope.home_path, out.items[2].scope);

    // client 정책 필터: host는 최대 집합으로 계산하고, client가 자기 프리셋으로 거른다. web 프리셋이면 경로는 빠진다.
    var visible: usize = 0;
    for (out.items) |l| {
        if (l.scope.enabledIn(selection.link_scopes_web)) visible += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), visible);
}

// OSC 8 명시 링크는 screen wire의 run에 셀 link id가 없어 원격 client에 전달되지 않는다. 그래서 host가 자동 감지와
// **같은 목록**에 실어 보내야 원격에서도 명시 링크의 밑줄/열기가 산다(scope=osc8은 config 프리셋과 무관하게 표시).
test "collectViewportLinks: OSC 8 명시 링크를 osc8 scope로 함께 싣는다" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 40, .rows = 4 });
    defer core.deinit();
    var out: std.ArrayList(selection.ViewportLink) = .empty;
    defer out.deinit(allocator);

    // 보이는 텍스트("docs")는 링크처럼 생기지 않았지만 OSC 8 URI가 붙어 있다 — 자동 감지로는 절대 안 잡힌다.
    try core.write("\x1b]8;;https://example.com/deep\x1b\\docs\x1b]8;;\x1b\\ tail");
    try selection.collectViewportLinks(&core, allocator, selection.link_scopes_full, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(selection.LinkScope.osc8, out.items[0].scope);
    try std.testing.expectEqual(selection.LinkKind.url, out.items[0].kind);
    try std.testing.expectEqual(@as(u16, 0), out.items[0].span.start.col);
    try std.testing.expectEqual(@as(u16, 3), out.items[0].span.end.col); // "docs" 4칸
    // osc8은 어떤 프리셋에서도 표시된다(로컬에서 OSC 8이 scope 토글과 무관한 것과 동일).
    try std.testing.expect(out.items[0].scope.enabledIn(selection.link_scopes_none));
}

// soft-wrap으로 다음 행까지 이어진 링크는 두 행에 걸치지만 **하나의 링크**다. 행 단위로 스캔하면서 이어진 run을
// 다시 분류해 중복 방출하면 client가 같은 밑줄을 두 번 그리고, 뒤 조각이 잘린 토큰으로 오분류될 수 있다.
test "collectViewportLinks: soft-wrap된 링크를 중복 없이 한 번만 방출한다" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 20, .rows = 6 });
    defer core.deinit();
    var out: std.ArrayList(selection.ViewportLink) = .empty;
    defer out.deinit(allocator);

    try core.write("https://example.com/a/very/long/path"); // 20칸 폭이라 여러 행으로 wrap
    try selection.collectViewportLinks(&core, allocator, selection.link_scopes_full, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(selection.LinkKind.url, out.items[0].kind);
    try std.testing.expect(out.items[0].span.end.row > out.items[0].span.start.row); // 실제로 wrap을 태웠다
}

// [경로 semantics] 아래 링크·클릭 경로 테스트 3개는 **POSIX 경로 전제**다: 절대 경로 = 선행 `/`, 구분자 = `/`,
// 홈 = `$HOME`, cwd 조회 = libc `getcwd`. Windows는 드라이브 문자(`D:\`)·백슬래시·`%USERPROFILE%`로 이 넷이 전부
// 다르고, 그건 link-detection.md가 아직 정하지 않은 **설계 결정**이다. 여기서 억지로 통과시키면(경로를 OS별로
// 조립해 주는 식) 링크 감지가 Windows에서 동작하는 것처럼 보이지만 실제 제품 판정(`isAbsolute`·존재 게이트)은
// 그대로 POSIX라, 테스트만 초록인 상태가 된다. 그래서 정직하게 POSIX에서만 돌리고 Windows는 skip으로 남긴다.
test "extractUrlAt resolves and existence-gates file paths (absolute + OSC 7 cwd-relative)" {
    // file_path 링크는 실제로 존재할 때만 절대 경로로 열린다(오탐·미존재 차단). 절대 경로는 cwd 없이,
    // bare/상대 경로는 OSC 7 cwd 기준으로 resolve. tmpDir에 실파일을 만들어 검증한다.
    if (builtin.os.tag == .windows) return error.SkipZigTest; // 아래 [경로 semantics] 참조
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/real.txt", .data = "x" });
    // tmpDir은 .zig-cache/tmp/<sub_path>에 생긴다(다른 테스트의 tmpSubPath 관례). OSC 7 cwd엔 절대 경로가 필요하니
    // process cwd(repo root)와 합쳐 절대 경로로 만든다(std.Io엔 realpath/getcwd가 없어 libc getcwd — 테스트 전용).
    var cwd_buf: [4096]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len); // buf를 NUL-종료 절대 cwd로 채운다(테스트 환경 성공 가정)
    const proc_cwd = std.mem.sliceTo(&cwd_buf, 0);
    const tmp_abs = try std.fs.path.join(std.testing.allocator, &.{ proc_cwd, ".zig-cache/tmp", &tmp.sub_path });
    defer std.testing.allocator.free(tmp_abs);
    const abs_file = try std.fs.path.join(std.testing.allocator, &.{ tmp_abs, "sub/real.txt" });
    defer std.testing.allocator.free(abs_file);

    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 200, .rows = 4 });
    defer core.deinit();
    const full = selection.link_scopes_full;

    // (1) 절대 경로(존재) — cwd 없이 감지·resolve.
    try core.write(abs_file);
    try core.write("\r\n");
    {
        const got = (try core.extractUrlAt(std.testing.allocator, 0, 0, full)).?;
        defer std.testing.allocator.free(got.text);
        try std.testing.expectEqual(selection.LinkKind.file_path, got.kind);
        try std.testing.expectEqualStrings(abs_file, got.text);
    }

    // OSC 7로 셸 cwd를 tmp로 보고(file://host/<path>).
    try core.write("\x1b]7;file://host");
    try core.write(tmp_abs);
    try core.write("\x1b\\");
    try std.testing.expectEqualStrings(tmp_abs, core.currentCwd());

    // (2) bare 상대 경로(존재) — cwd 기준 resolve → 같은 절대 경로.
    try core.write("sub/real.txt\r\n"); // row 1
    {
        const got = (try core.extractUrlAt(std.testing.allocator, 1, 0, full)).?;
        defer std.testing.allocator.free(got.text);
        try std.testing.expectEqualStrings(abs_file, got.text);
    }

    // (3) 존재하지 않는 상대 경로 → null(존재 게이트).
    try core.write("sub/nope.txt\r\n"); // row 2
    try std.testing.expect((try core.extractUrlAt(std.testing.allocator, 2, 0, full)) == null);
}

test "resolveClickedPath: cwd-relative resolve, normalization, line:col strip, directory, existence gate" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // 아래 [경로 semantics] 참조
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/real.txt", .data = "x" });
    var cwd_buf: [4096]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len);
    const proc_cwd = std.mem.sliceTo(&cwd_buf, 0);
    const A = std.testing.allocator;
    const tmp_abs = try std.fs.path.join(A, &.{ proc_cwd, ".zig-cache/tmp", &tmp.sub_path });
    defer A.free(tmp_abs);
    const abs_file = try std.fs.path.join(A, &.{ tmp_abs, "sub/real.txt" });
    defer A.free(abs_file);
    const sub_dir = try std.fs.path.join(A, &.{ tmp_abs, "sub" });
    defer A.free(sub_dir);

    var core = try TerminalCore.init(A, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]7;file://host"); // OSC 7로 cwd = tmp_abs
    try core.write(tmp_abs);
    try core.write("\x1b\\");

    const Check = struct {
        fn expect(c: *const TerminalCore, a: std.mem.Allocator, raw: []const u8, want: ?[]const u8) !void {
            const got = try c.resolveClickedPath(a, raw);
            if (want) |w| {
                const g = got orelse {
                    std.debug.print("resolveClickedPath({s}) = null, want {s}\n", .{ raw, w });
                    return error.TestUnexpectedResult;
                };
                defer a.free(g);
                try std.testing.expectEqualStrings(w, g);
            } else if (got) |g| {
                a.free(g);
                std.debug.print("resolveClickedPath({s}) matched, want null\n", .{raw});
                return error.TestUnexpectedResult;
            }
        }
    };

    try Check.expect(&core, A, abs_file, abs_file); // 절대(존재)
    try Check.expect(&core, A, "/no/such/file.zig", null); // 절대(미존재)
    try Check.expect(&core, A, "sub/real.txt", abs_file); // cwd 상대(존재)
    try Check.expect(&core, A, "sub/nope.txt", null); // cwd 상대(미존재)
    try Check.expect(&core, A, "sub/../sub/real.txt", abs_file); // 정규화(..)
    try Check.expect(&core, A, "./sub/real.txt", abs_file); // 정규화(./)
    try Check.expect(&core, A, "sub", sub_dir); // 디렉토리(존재)도 허용
    try Check.expect(&core, A, "sub/real.txt:42", abs_file); // :line 분리 후 stat
    try Check.expect(&core, A, "sub/real.txt:42:10", abs_file); // :line:col 분리
    try Check.expect(&core, A, "sub/real.txt:1:2:3", null); // 3단 콜론(한계) — :1 남아 미존재
}

// 테스트 전용 — Zig 0.16 std.c엔 setenv/unsetenv 바인딩이 없어 직접 extern 선언한다(pty/macos.zig 선례).
// **POSIX 전용**: Windows CRT는 이 둘 대신 `_putenv_s`를 준다. 아래 테스트가 POSIX에서만 도는 덕에 다른
// 타깃에선 참조되지 않아 분석·링크되지 않는다(참조되면 lld-link undefined symbol로 터진다 — 실측).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "resolveClickedPath: ~/ expands via $HOME, empty HOME rejected" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // 위 [경로 semantics] 참조
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "home.txt", .data = "x" });
    var cwd_buf: [4096]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len);
    const proc_cwd = std.mem.sliceTo(&cwd_buf, 0);
    const A = std.testing.allocator;
    const tmp_abs = try std.fs.path.join(A, &.{ proc_cwd, ".zig-cache/tmp", &tmp.sub_path });
    defer A.free(tmp_abs);
    const home_file = try std.fs.path.join(A, &.{ tmp_abs, "home.txt" });
    defer A.free(home_file);

    var core = try TerminalCore.init(A, .{ .cols = 8, .rows = 2 });
    defer core.deinit();

    // 원래 HOME을 저장(복원) — getenv 포인터는 setenv 후 무효라 값을 복사한다.
    const orig: ?[]u8 = if (std.c.getenv("HOME")) |h| try A.dupe(u8, std.mem.span(h)) else null;
    defer {
        if (orig) |o| {
            if (A.dupeZ(u8, o)) |z| {
                _ = setenv("HOME", z.ptr, 1);
                A.free(z);
            } else |_| {}
            A.free(o);
        } else _ = unsetenv("HOME");
    }

    const tmp_abs_z = try A.dupeZ(u8, tmp_abs);
    defer A.free(tmp_abs_z);
    _ = setenv("HOME", tmp_abs_z.ptr, 1);
    { // ~/home.txt → $HOME/home.txt
        const got = (try core.resolveClickedPath(A, "~/home.txt")).?;
        defer A.free(got);
        try std.testing.expectEqualStrings(home_file, got);
    }
    // 빈 HOME → "~/x"가 상대 "x"로 오인 resolve되지 않게 거부(isAbsolute 가드).
    _ = setenv("HOME", "", 1);
    try std.testing.expect((try core.resolveClickedPath(A, "~/home.txt")) == null);
}

test "extractUrlAt: OSC 8 file:// URI is kind=url and bypasses the existence gate (program-specified)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 40, .rows = 2 });
    defer core.deinit();
    // 프로그램이 OSC 8로 존재하지 않는 file:// URI를 지정 — 휴리스틱과 달리 게이트 없이 URI 그대로(kind=url).
    try core.write("\x1b]8;;file:///nonexistent/x.txt\x1b\\link\x1b]8;;\x1b\\");
    const got = (try core.extractUrlAt(std.testing.allocator, 0, 0, selection.link_scopes_full)).?;
    defer std.testing.allocator.free(got.text);
    try std.testing.expectEqual(selection.LinkKind.url, got.kind);
    try std.testing.expectEqualStrings("file:///nonexistent/x.txt", got.text);
}

test "wide glyph (한글) forcing a wrap keeps the link clickable across the wrap (heuristic + OSC 8)" {
    // 사용자 보고: 링크가 여러 줄로 강제개행될 때 클릭이 안 되는 경우. 루트커즈 — wide glyph가 줄 끝 한 칸에
    // 안 들어가 다음 행으로 밀리며 직전 행 끝에 padding 빈칸을 남기고(screen.zig), 그 빈칸이 단어/링크 run
    // 이음을 끊었다. wrapped 행의 trailing padding을 건너뛰도록 wordBoundsAtImpl·linkBoundsAt를 고쳤다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    const full = selection.link_scopes_full;

    // (휴리스틱) "/aaaaaa한bc" — '한'(width 2)이 col7에 안 들어가 다음 행으로 밀리며 row0 col7에 padding 빈칸.
    try core.write("/aaaaaa한bc");
    try std.testing.expect(core.screen.wrapped[0]);
    // 둘째 행(한bc) 클릭 → wrap 너머 전체 경로 토큰(존재 게이트 전 순수 분류 selection.extractUrlAt).
    {
        const got = (try selection.extractUrlAt(&core, std.testing.allocator, 1, 0, full)).?;
        defer std.testing.allocator.free(got.text);
        try std.testing.expectEqualStrings("/aaaaaa한bc", got.text);
        try std.testing.expectEqual(selection.LinkKind.file_path, got.kind);
    }
    // 첫 행(/aaaaaa) 클릭도 전체(오른쪽 이음이 padding을 넘어 둘째 행과 이어야).
    {
        const got = (try selection.extractUrlAt(&core, std.testing.allocator, 0, 0, full)).?;
        defer std.testing.allocator.free(got.text);
        try std.testing.expectEqualStrings("/aaaaaa한bc", got.text);
    }

    // (OSC 8) wide glyph wrap에서 밑줄 anchor가 토막나지 않고 run 시작(첫 행)으로 수렴.
    var core2 = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core2.deinit();
    try core2.write("\x1b]8;;https://x.y/z\x1b\\aaaaaaa한bc\x1b]8;;\x1b\\");
    try std.testing.expect(core2.screen.wrapped[0]);
    const anchor = core2.urlAnchorAt(1, 0, full).?; // 둘째 행 hover
    try std.testing.expectEqual(@as(usize, 0), anchor.row); // run 시작은 첫 행(밑줄 토막 안 남)
    try std.testing.expectEqual(@as(u16, 0), anchor.col);
}

test "extractUrlAt does NOT join a link split by a hard newline (only soft-wrap joins)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 40, .rows = 3 });
    defer core.deinit();
    // hard newline(\r\n)으로 쪼개진 경로 — 다른 논리 줄이라 이어붙이면 안 된다(soft-wrap만 잇는다).
    try core.write("/aaa/bbb\r\nccc/ddd.txt");
    try std.testing.expect(!core.screen.wrapped[0]); // soft-wrap 아님(hard 개행)
    const got = (try selection.extractUrlAt(&core, std.testing.allocator, 0, 0, selection.link_scopes_full)).?;
    defer std.testing.allocator.free(got.text);
    try std.testing.expectEqualStrings("/aaa/bbb", got.text); // 둘째 줄(ccc/ddd.txt)은 안 붙는다
}

test "wide glyph wrap: hover (wordIsUrl) on both rows + underline span (urlSpanAtAbs) covers the wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    const full = selection.link_scopes_full;
    // 'http://'=7칸, '한'(width 2)이 col7에 안 들어가 wide-push → row0="http://"+padding, row1="한x".
    try core.write("http://한x");
    try std.testing.expect(core.screen.wrapped[0]);
    // hover 판정(존재 게이트 없는 휴리스틱)이 양쪽 행 모두 링크.
    try std.testing.expect(selection.wordIsUrl(&core, 0, 0, full));
    try std.testing.expect(selection.wordIsUrl(&core, 1, 0, full));
    // 밑줄 anchor는 run 시작(첫 행), 밑줄 span은 둘째 행까지 걸친다.
    const anchor = core.urlAnchorAt(1, 0, full).?;
    try std.testing.expectEqual(@as(usize, 0), anchor.row);
    const span = core.urlSpanAtAbs(anchor).?;
    try std.testing.expectEqual(@as(u16, 0), span.start.row);
    try std.testing.expectEqual(@as(u16, 1), span.end.row);
}

test "wide emoji (⏰) forcing a wrap keeps the path clickable across the wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    // ⏰(U+23F0, Emoji_Presentation width 2)도 한글과 같은 wide-push padding을 만든다.
    try core.write("/aaaaaa⏰bc");
    try std.testing.expect(core.screen.wrapped[0]);
    const got = (try selection.extractUrlAt(&core, std.testing.allocator, 1, 0, selection.link_scopes_full)).?;
    defer std.testing.allocator.free(got.text);
    try std.testing.expectEqualStrings("/aaaaaa⏰bc", got.text);
}

test "extractUrlAt: link wrapping three rows is fully recovered from any row" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    const full = selection.link_scopes_full;
    // 20칸 경로 → 8+8+4 3행 soft-wrap(ASCII, padding 없음).
    try core.write("/aaa/bbb/ccc/ddd.zig");
    try std.testing.expect(core.screen.wrapped[0]);
    try std.testing.expect(core.screen.wrapped[1]);
    // 첫·둘째·셋째 행 어디서 클릭해도 전체 경로를 회수.
    for ([_]u16{ 0, 1, 2 }) |r| {
        const got = (try selection.extractUrlAt(&core, std.testing.allocator, r, 0, full)).?;
        defer std.testing.allocator.free(got.text);
        try std.testing.expectEqualStrings("/aaa/bbb/ccc/ddd.zig", got.text);
    }
}

test "clicking the continuation half of a wide glyph still resolves the whole link" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();
    // 'https://'(col0-7), '한'(col8-9), '국'(col10-11), '.com'(col12-15). col9 = '한'의 continuation 칸.
    try core.write("https://한국.com");
    const got = (try selection.extractUrlAt(&core, std.testing.allocator, 0, 9, selection.link_scopes_full)).?;
    defer std.testing.allocator.free(got.text);
    try std.testing.expectEqualStrings("https://한국.com", got.text); // continuation 칸 클릭도 전체 URL
}

test "wordIsUrl handles a token longer than its 2048-byte scratch buffer" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3000, .rows = 2 });
    defer core.deinit();
    // 2048바이트를 넘는 긴 http URL — wordIsUrl의 스택 버퍼가 넘쳐도 앞쪽 prefix에 스킴이 있고 잘림(`…`)이
    // 없으므로 링크로 본다.
    try core.write("https://");
    var i: usize = 0;
    while (i < 2100) : (i += 1) try core.write("a");
    try std.testing.expect(selection.wordIsUrl(&core, 0, 0, selection.link_scopes_full));
}

test "ellipsis past the 2048-byte scratch buffer: hover and click agree (both reject)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3000, .rows = 2 });
    defer core.deinit();
    // 잘림 마커 `…`가 hover의 2048B 스크래치 버퍼 너머에 오는 긴 URL. hover(wordIsUrl)는 버퍼만, click
    // (extractUrlAt)은 전체 토큰을 본다 — 어긋나면 "밑줄은 떠도 클릭하면 안 열림". 둘 다 거부로 일치해야 한다.
    try core.write("https://");
    var i: usize = 0;
    while (i < 2100) : (i += 1) try core.write("a");
    try core.write("…");
    try std.testing.expect(!selection.wordIsUrl(&core, 0, 0, selection.link_scopes_full));
    try std.testing.expect((try core.extractUrlAt(std.testing.allocator, 0, 0, selection.link_scopes_full)) == null);
}

// 절대경로 감지는 오래도록 `word[0] == '/'`였다. Windows에서는 **실재하는** `C:\...`조차 밑줄도 안 뜨고 열리지도
// 않았다(docs/windows-platform.md §5 실측). 고치되 macOS는 건드리면 안 된다 — hover(wordIsUrl)는 비용 때문에
// 존재검증을 하지 않으므로, macOS에서 `C:\x`를 감지하면 "밑줄은 뜨는데 클릭하면 아무 일도 없는" 상태가 확정된다.
// 그래서 술어를 **호스트 OS 기준**으로 둔다(path_shape.isDetectableAbsolute — VS Code가 백엔드 OS를 쓰는 것과 같은 규칙).
//
// **이 테스트가 검증하는 것은 배선이다** — selection.zig가 정말 그 술어를 쓰는가. 술어 자체의 의미(어떤 모양을
// 어떤 OS 기준으로 잡는가, 그리고 `감지 ⊆ std.fs.path.isAbsolute` 불변식)는 `path_shape.zig`에서 OS를 **인자로**
// 받아 두 갈래를 모두 실행한다. 그래서 Windows 러너가 없는 CI에서도 Windows 분기가 공허참이 되지 않는다.
test "absolute-path link detection follows the host OS, and never outruns resolve's notion of absolute" {
    const on_windows = @import("builtin").os.tag == .windows;
    const full = selection.link_scopes_full;

    const Case = struct { text: []const u8, want: bool, why: []const u8 };
    const cases = [_]Case{
        // 어느 호스트에서나 오늘과 같다.
        .{ .text = "/Users/me/a.zig", .want = true, .why = "POSIX 절대 — 기존 동작" },
        .{ .text = "//server/share", .want = false, .why = "`//` 배제는 그대로" },
        // Windows에서만 새로 잡힌다.
        .{ .text = "C:\\Users\\me\\a.zig", .want = on_windows, .why = "드라이브 절대(역슬래시)" },
        .{ .text = "C:/Users/me/a.zig", .want = on_windows, .why = "드라이브 절대(슬래시)" },
        .{ .text = "d:\\lower\\a.zig", .want = on_windows, .why = "소문자 드라이브" },
        // 어느 호스트에서도 안 잡혀야 한다 — resolveClickedPath가 절대로 안 보는 모양이라
        // 잡으면 cwd에 join돼 엉뚱한 파일을 연다.
        .{ .text = "a:b", .want = false, .why = "드라이브처럼 생겼을 뿐" },
        .{ .text = "C:relative", .want = false, .why = "드라이브 상대 — isAbsolute=false" },
        .{ .text = "\\foo\\bar", .want = false, .why = "드라이브 없는 루트 상대 + 이스케이프 출력 오탐" },
        .{ .text = "\\\\server\\share\\f.txt", .want = false, .why = "UNC — 술어가 직접 배제한다" },
        // Win32는 드라이브 문자를 A–Z로 제한하지 않는다(`std.fs.path.isAbsoluteWindows("1:/x") == true`).
        // 가드가 OS 파서보다 좁으면 그 차이가 우회로가 되므로 `path_shape`가 종류를 묻지 않게 바뀌었고,
        // 감지도 같은 파서를 쓴다 — 그래서 Windows에서는 이것도 진짜 경로다.
        .{ .text = "1:\\drive-one", .want = on_windows, .why = "비알파벳 드라이브도 Win32에선 절대다" },
        // **알려진 오탐 — 의도적으로 남긴다.** 한 글자 라벨 + 이스케이프(`n:\t`)나 드라이브 루트(`y:\`)도
        // 드라이브 절대 모양이다. POSIX 쪽도 오늘 같은 등급의 오탐을 낸다 — `/t`나 sed의 `/foo/bar/`가
        // `absolute_path`로 잡힌다. 여기만 좁히면 "왜 `/t`는 밑줄이 뜨는데 `C:\t`는 안 뜨나"가 설명되지 않는
        // 비대칭이 생긴다. 실제 피해(엉뚱한 파일 열기)는 존재 게이트가 막는다. 근본 해결은 hover에도 stat을
        // 두는 것(VS Code 방식)이고 이 슬라이스 범위 밖이다.
        .{ .text = "n:\\t", .want = on_windows, .why = "알려진 오탐 — POSIX `/t`와 같은 등급" },
        .{ .text = "y:\\", .want = on_windows, .why = "알려진 오탐 — 드라이브 루트(POSIX `/`와 대칭)" },
    };

    for (cases) |c| {
        var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 80, .rows = 2 });
        defer core.deinit();
        try core.write(c.text);

        // hover(할당 없는 분류)와 순수 분류기가 같은 답을 내야 한다 — 원격 span(collectViewportLinks)도 후자를 쓴다.
        const hovered = selection.wordIsUrl(&core, 0, 0, full);
        const span = selection.linkSpanInWord(c.text, full);
        const classified = span != null and span.?.kind == .file_path and span.?.scope == .absolute_path;
        if (hovered != c.want or classified != c.want) {
            std.debug.print("\"{s}\" ({s}): hover={} classify={} want={}\n", .{ c.text, c.why, hovered, classified, c.want });
            return error.TestUnexpectedResult;
        }
    }
}

test "urlSpanAtAbs keeps a hovered link's underline within the viewport across scrolling (no OOB)" {
    // hover 밑줄 범위(urlSpanAtAbs)는 선택 하이라이트와 같은 clipAbsSpanToViewport로 클립된다. 링크가
    // 스크롤백으로 밀리거나 화면 경계에 걸쳐도 밑줄 좌표가 화면 범위[0, rows)를 벗어나면 안 된다(OOB/stale 방지).
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 16, .rows = 3 });
    defer core.deinit();
    core.setMaxScrollback(20);
    const full = selection.link_scopes_full;

    try core.write("https://a.bc/xy\r\n"); // 한 행에 들어가는 URL
    const anchor = core.urlAnchorAt(0, 0, full).?; // abs 좌표(스크롤과 무관하게 내용을 따라감)
    // 보이는 동안: 밑줄 span은 화면 범위 안.
    {
        const s = core.urlSpanAtAbs(anchor).?;
        try std.testing.expect(s.start.row < core.size.rows and s.end.row < core.size.rows);
    }
    // 여러 줄을 더 써서 링크를 스크롤백 위로 밀어낸다(뷰포트는 bottom).
    try core.write("l2\r\nl3\r\nl4\r\nl5\r\nl6\r\n");
    // 화면 밖이면 null, 일부 보이면 클립 — 어느 경우든 OOB(>= rows) 좌표는 안 나온다.
    if (core.urlSpanAtAbs(anchor)) |s| {
        try std.testing.expect(s.start.row < core.size.rows and s.end.row < core.size.rows);
    }
    // 위로 스크롤(delta_up>0)해서 링크가 화면 상단 경계에 다시 걸쳐도 클립 유지.
    core.scrollViewport(3);
    if (core.urlSpanAtAbs(anchor)) |s| {
        try std.testing.expect(s.start.row < core.size.rows and s.end.row < core.size.rows);
        try std.testing.expect(s.start.row <= s.end.row);
    }
}

test "selection is invalidated by row-relocating ops that break absolute coords" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();

    // resize(폭 변경): 활성 화면이 reflow돼 선택 해제.
    try core.write("ab\r\ncd");
    core.selectionStart(0, 0);
    core.selectionExtend(1, 1);
    try std.testing.expect(core.selection_anchor != null);
    try core.resize(6, 3);
    try std.testing.expect(core.selection_anchor == null);

    // resize(높이만): 폭 불변이라도 해제(이전엔 안 했음).
    core.selectionStart(0, 0);
    try core.resize(6, 2);
    try std.testing.expect(core.selection_anchor == null);

    // IL/DL(scrollRangeDown/Up, 부분 이동): 해제.
    try core.write("\x1b[1;1Hx\r\ny");
    core.selectionStart(0, 0);
    try core.write("\x1b[L"); // IL
    try std.testing.expect(core.selection_anchor == null);
    core.selectionStart(0, 0);
    try core.write("\x1b[M"); // DL
    try std.testing.expect(core.selection_anchor == null);

    // alt screen 전환: 진입/복귀 모두 해제.
    core.selectionStart(0, 0);
    try core.write("\x1b[?1049h");
    try std.testing.expect(core.selection_anchor == null);
    core.selectionStart(0, 0);
    try core.write("\x1b[?1049l");
    try std.testing.expect(core.selection_anchor == null);

    // ED 3(clearScrollback): 해제.
    try core.write("p\r\nq\r\nr\r\ns"); // 스크롤백 생성
    core.selectionStart(0, 0);
    try core.write("\x1b[3J");
    try std.testing.expect(core.selection_anchor == null);
}

test "selection still follows content through a full-screen scroll (preserved case)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("aa\r\nbb"); // 화면 [aa, bb]
    core.selectionStart(0, 0);
    core.selectionExtend(0, 1); // "aa"(활성 행0)
    try core.write("\r\ncc"); // 전체 화면 스크롤: aa -> 스크롤백, 선택은 따라가 유지
    try std.testing.expect(core.selection_anchor != null);
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("aa", text);
}

test "selectAll selects scrollback + screen regardless of scroll position" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // "a"가 스크롤백으로, "b"/"c"가 화면에 남게(2행 화면). sb_count=1, 화면 [b, c].
    try core.write("a\r\nb\r\nc");
    try std.testing.expect(core.screen.sb.count >= 1);

    core.selectAll();
    // anchor=첫 스크롤백 행(abs 0, col 0), head=마지막 화면 행(abs sb_count+rows-1).
    try std.testing.expectEqual(@as(usize, 0), core.selection_anchor.?.row);
    try std.testing.expectEqual(@as(u16, 0), core.selection_anchor.?.col);
    try std.testing.expectEqual(core.screen.sb.count + core.size.rows - 1, core.selection_head.?.row);

    // 추출하면 전체 내용(스크롤백 a + 화면 b,c)이 줄바꿈으로 잡힌다(빈 칸 trim).
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a\nb\nc", text);

    // 스크롤 위치와 무관: 위로 스크롤한 뒤에도 같은 절대 범위.
    core.selectionClear();
    core.scrollViewport(1); // 위로 1행 스크롤(스크롤백 노출)
    core.selectAll();
    try std.testing.expectEqual(@as(usize, 0), core.selection_anchor.?.row);
    try std.testing.expectEqual(core.screen.sb.count + core.size.rows - 1, core.selection_head.?.row);
}

test "scrollback re-wrap clears a truncated wide-glyph base at narrow widths" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\xed\x95\x9c\xed\x95\x9c\r\n1\r\n2"); // "한한"(wide) 한 줄이 스크롤백으로
    try std.testing.expect(core.scrollbackLen() >= 1);
    try core.resize(2, 2); // 2칸 — 한(width2)이 한 칸씩 차지
    core.scrollViewport(10); // 재-wrap 트리거
    // 재-wrap된 스크롤백 행의 마지막 칸이 잘린 wide base(width 2)로 남지 않아야 한다.
    var r: usize = 0;
    while (r < core.scrollbackLen()) : (r += 1) {
        const row = core.scrollbackRow(r).?;
        if (row.len > 0) try std.testing.expect(row[row.len - 1].width != 2);
    }
}

test "grapheme_store: intern/lookup/append round-trip + dedup (link_ids 패턴)" {
    // 왜 중요: NFD 한글·ZWJ 시퀀스의 cluster 본체가 셀 밖 store에 무손실로 담겨야(잘림 금지)
    // 클립보드·재출력·trace가 전체 코드포인트를 복원한다. 그리고 link과 같이 dedup해 같은 cluster를
    // 한 번만 저장 — store가 셀 수가 아니라 distinct cluster 수만큼만 커진다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();

    try std.testing.expectEqual(@as(?[]const u21, null), core.graphemeCluster(0)); // 0=없음

    const id1 = try core.internGrapheme(&.{ 0x1161, 0x11AB }); // '한'의 V·T
    try std.testing.expectEqual(@as(u32, 1), id1); // 인덱스+1
    try std.testing.expectEqualSlices(u21, &.{ 0x1161, 0x11AB }, core.graphemeCluster(id1).?);

    const id2 = try core.internGrapheme(&.{0x0301}); // 다른 cluster — 새 id
    try std.testing.expectEqual(@as(u32, 2), id2);

    // **dedup**: 같은 cluster를 다시 intern하면 같은 id를 돌려주고 store는 안 커진다.
    const id1_again = try core.internGrapheme(&.{ 0x1161, 0x11AB });
    try std.testing.expectEqual(id1, id1_again);
    try std.testing.expectEqual(@as(usize, 2), core.grapheme_store.items.len); // 2개 그대로

    // append: 기존 cluster 뒤에 cp 하나 더한 새 cluster를 intern.
    const id3 = try core.appendGraphemeCodepoint(id1, 0x0323);
    try std.testing.expectEqual(@as(u32, 3), id3);
    try std.testing.expectEqualSlices(u21, &.{ 0x1161, 0x11AB, 0x0323 }, core.graphemeCluster(id3).?);
    try std.testing.expectEqualSlices(u21, &.{ 0x1161, 0x11AB }, core.graphemeCluster(id1).?); // 불변
    // 같은 append를 또 하면 dedup으로 id3 재사용(store 불변).
    try std.testing.expectEqual(id3, try core.appendGraphemeCodepoint(id1, 0x0323));
    try std.testing.expectEqual(@as(usize, 3), core.grapheme_store.items.len);
    // id=0에서 append면 빈 것 뒤에 붙어 1개짜리 cluster가 된다.
    const id4 = try core.appendGraphemeCodepoint(0, 0x1175);
    try std.testing.expectEqualSlices(u21, &.{0x1175}, core.graphemeCluster(id4).?);

    // 범위 밖 id는 null(안전).
    try std.testing.expectEqual(@as(?[]const u21, null), core.graphemeCluster(999));

    // RIS(하드 리셋)는 store·dedup 맵을 비운다(셀도 함께 사라져 dangling 없음).
    core.fullReset();
    try std.testing.expectEqual(@as(usize, 0), core.grapheme_store.items.len);
    try std.testing.expectEqual(@as(u32, 0), core.grapheme_ids.size);
    // 리셋 후 다시 intern하면 id가 1부터 재시작(dedup 맵도 비워졌다).
    try std.testing.expectEqual(@as(u32, 1), try core.internGrapheme(&.{ 0x1161, 0x11AB }));
}

test "grapheme dedup: 힙 버퍼(다른 메모리)로 같은 cluster를 intern해도 같은 id (값 기반 해시)" {
    // 회귀 고정: u21은 stride 4바이트(21 값 비트 + padding). `alloc(u21)`로 만든 버퍼는 값 store가 alignment
    // 바이트를 안 건드려(plat. 따라) alloc 잔재가 padding에 남을 수 있다. 옛 해시(`sliceAsBytes([]u21)`)는 그
    // dirty padding까지 해시해 — 같은 cluster라도 매 alloc마다 padding이 달라 다른 해시 → getContext miss →
    // dedup이 같은 cluster를 store에 또 쌓는다(PR #991 잠재 버그, store 무한 증가). 값 기반 해시(u32 widen)면
    // padding과 무관하게 같은 값→같은 해시→dedup HIT. 여기선 **별도 힙 버퍼**로 같은 값을 intern해도 한
    // entry임을 고정한다(comptime 리터럴 재사용 dedup 테스트는 padding이 우연 일치해 이 경로를 못 짚었다).
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    const id1 = try core.internGrapheme(&.{ 0x1161, 0x11AB });
    try std.testing.expectEqual(@as(usize, 1), core.grapheme_store.items.len);

    // 같은 값을 별도 힙 alloc 버퍼(다른 주소·다른 padding 잔재 가능)로 intern → 값이 같으니 같은 id, store 불변.
    const buf = try std.testing.allocator.alloc(u21, 2);
    defer std.testing.allocator.free(buf);
    buf[0] = 0x1161;
    buf[1] = 0x11AB;
    try std.testing.expectEqual(id1, try core.internGrapheme(buf));
    try std.testing.expectEqual(@as(usize, 1), core.grapheme_store.items.len); // dedup — 안 커진다
}

test "OSC 8 hyperlink: click returns the stored URI regardless of visible text" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    // "여기" 두 글자(wide)에 링크. ST(ESC \) 종료.
    try core.write("\x1b]8;;https://maru.dev/docs\x1b\\click here\x1b]8;;\x1b\\ tail");
    // 링크 텍스트 위 클릭 — 보이는 텍스트("click here")가 아니라 지정 URI가 나온다.
    const url = (try core.extractUrlAt(std.testing.allocator, 0, 2, selection.link_scopes_full)).?;
    defer std.testing.allocator.free(url.text);
    try std.testing.expectEqualStrings("https://maru.dev/docs", url.text);
    try std.testing.expect(selection.wordIsUrl(&core, 0, 2, selection.link_scopes_full));
    // 링크 안 공백("click here"의 ' ')도 같은 링크다.
    try std.testing.expect(selection.wordIsUrl(&core, 0, 5, selection.link_scopes_full));
    // 링크 밖("tail")은 아니다.
    try std.testing.expect(!selection.wordIsUrl(&core, 0, 12, selection.link_scopes_full));
    // 닫은 뒤 출력엔 링크가 없다.
    try std.testing.expectEqual(@as(u32, 0), core.screen.cells[12].link);
}

test "OSC 8 hyperlink: ellipsized visible text still opens the stored URI" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 40, .rows = 3 });
    defer core.deinit();
    // 화면 텍스트가 말줄임되어도 OSC 8 셀 메타데이터가 원본 URI를 들고 있으면 그 원본을 연다.
    try core.write("\x1b]8;;https://example.com/full/path/to/report\x1b\\https://example.com/full/…\x1b]8;;\x1b\\");
    const url = (try core.extractUrlAt(std.testing.allocator, 0, 25, selection.link_scopes_full)).?;
    defer std.testing.allocator.free(url.text);
    try std.testing.expectEqual(selection.LinkKind.url, url.kind);
    try std.testing.expectEqualStrings("https://example.com/full/path/to/report", url.text);
    try std.testing.expect(selection.wordIsUrl(&core, 0, 25, selection.link_scopes_full));
}

test "OSC 8 hyperlink: BEL terminator, id= params ignored, same URI interned once" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 30, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]8;id=x;https://a.bc\x07one\x1b]8;;\x07 \x1b]8;;https://a.bc\x07two\x1b]8;;\x07");
    try std.testing.expectEqual(@as(usize, 1), core.link_store.items.len); // dedup
    try std.testing.expectEqual(core.screen.cells[0].link, core.screen.cells[5].link); // 같은 id 재사용
    const url = (try core.extractUrlAt(std.testing.allocator, 0, 0, selection.link_scopes_full)).?;
    defer std.testing.allocator.free(url.text);
    try std.testing.expectEqualStrings("https://a.bc", url.text);
}

test "OSC 8 hyperlink: span underlines the whole link run and survives soft-wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]8;;https://a.bc/long\x1b\\abcdefgh\x1b]8;;\x1b\\"); // 6칸 wrap: abcdef|gh
    try std.testing.expect(core.screen.wrapped[0]);
    const anchor = core.urlAnchorAt(1, 1, selection.link_scopes_full).?; // 둘째 줄에서 클릭해도
    try std.testing.expectEqual(@as(usize, 0), anchor.row); // run 시작은 첫 줄
    const span = core.urlSpanAtAbs(anchor).?;
    try std.testing.expectEqual(@as(u16, 0), span.start.row);
    try std.testing.expectEqual(@as(u16, 0), span.start.col);
    try std.testing.expectEqual(@as(u16, 1), span.end.row);
    try std.testing.expectEqual(@as(u16, 1), span.end.col); // "gh"까지
    const url = (try core.extractUrlAt(std.testing.allocator, 1, 0, selection.link_scopes_full)).?;
    defer std.testing.allocator.free(url.text);
    try std.testing.expectEqualStrings("https://a.bc/long", url.text);
}

test "OSC 8 oversized URI is ignored and plain heuristic still works" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 30, .rows = 3 });
    defer core.deinit();
    // 버퍼(2048)를 넘는 OSC — 통째로 무시되고 출력은 정상.
    var big: [3000]u8 = undefined;
    @memset(&big, 'u');
    try core.write("\x1b]8;;https://");
    try core.write(&big);
    try core.write("\x07hello");
    try std.testing.expectEqual(@as(usize, 0), core.link_store.items.len);
    try std.testing.expectEqual(@as(u21, 'h'), core.screen.cells[0].codepoint);
    // 휴리스틱은 여전히 동작.
    try core.write("\r\nhttps://x.yz ");
    try std.testing.expect(selection.wordIsUrl(&core, 1, 3, selection.link_scopes_full));
}

test "heuristic link detection rejects ellipsized visible URLs" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 48, .rows = 2 });
    defer core.deinit();
    // OSC 8 없이 화면 텍스트 자체가 `…`로 잘렸으면 원본을 복원할 방법이 없으므로 링크 후보로 보지 않는다.
    try core.write("https://example.com/full/…");
    try std.testing.expect(!selection.wordIsUrl(&core, 0, 2, selection.link_scopes_full));
    try std.testing.expect((try core.extractUrlAt(std.testing.allocator, 0, 2, selection.link_scopes_full)) == null);
}

test "heuristic link detection keeps a complete link when the ellipsis is outside its span" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 48, .rows = 2 });
    defer core.deinit();
    // `…`가 스킴 앞에 있으면 잘린 건 앞쪽 텍스트지 URL이 아니다 — 뒤따르는 온전한 URL은 hover·click 모두
    // 감지하고 원본을 그대로 연다(토큰에 `…`가 있다는 이유만으로 거부하던 회귀의 가드).
    try core.write("…https://example.com/page"); // `…`=col0, URL은 col1부터
    try std.testing.expect(selection.wordIsUrl(&core, 0, 4, selection.link_scopes_full));
    const url = (try core.extractUrlAt(std.testing.allocator, 0, 4, selection.link_scopes_full)).?;
    defer std.testing.allocator.free(url.text);
    try std.testing.expectEqual(selection.LinkKind.url, url.kind);
    try std.testing.expectEqualStrings("https://example.com/page", url.text);
}

test "preedit composition shows the in-progress hangul at the cursor without touching the grid" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    var overlay = @import("preedit.zig").Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try core.write("$ ");

    try overlay.replace("안"); // 조합 중(wide)
    const snap = overlay.compose(core.renderSnapshot());
    // 커서 위치(0,2)에 '안'이 반전으로 합성되고, 커서는 그 뒤(0,4)로 보인다.
    try std.testing.expectEqual(@as(u21, 0xC548), snap.cells[2].codepoint);
    try std.testing.expect(snap.cells[2].style.reverse);
    try std.testing.expectEqual(@as(u2, 2), snap.cells[2].width);
    try std.testing.expect(snap.cells[3].continuation);
    try std.testing.expect(!snap.cursor.visible); // 조합 중 블록 커서 숨김(반전 preedit이 커서 역할)
    // 실제 그리드는 오염되지 않는다.
    try std.testing.expect(types.isUnwritten(core.screen.cells[2]));

    // 조합 갱신('않' 등 다른 글자로 교체)도 같은 자리에.
    try overlay.replace("않");
    const snap2 = overlay.compose(core.renderSnapshot());
    try std.testing.expectEqual(@as(u21, 0xC54A), snap2.cells[2].codepoint);

    // 조합 종료 — 합성이 사라지고 일반 snapshot으로 돌아간다.
    try overlay.replace("");
    const snap3 = overlay.compose(core.renderSnapshot());
    try std.testing.expect(types.isUnwritten(snap3.cells[2]));
    try std.testing.expectEqual(@as(u16, 2), snap3.cursor.col);
}

test "preedit clips at the row end instead of wrapping" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    var overlay = @import("preedit.zig").Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try core.write("abc"); // 커서 (0,3) — 한 칸 남음
    try overlay.replace("한"); // wide(2칸)는 안 들어간다 — 잘림
    const snap = overlay.compose(core.renderSnapshot());
    try std.testing.expectEqual(@as(u21, 'c'), snap.cells[2].codepoint);
    try std.testing.expect(!snap.cursor.visible);
}

test "preedit inserts mid-line, pushing the next glyphs right (가나다 + 나앞 조합 → 가[라]나다)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    var overlay = @import("preedit.zig").Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try core.write("\xea\xb0\x80\xeb\x82\x98\xeb\x8b\xa4"); // "가나다": 가=0,나=2,다=4 (각 wide)
    try core.write("\x1b[4D"); // 커서를 '나' base(col2)로 — 왼쪽 4칸 이동(글자는 그대로)
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);

    try overlay.replace("\xeb\x9d\xbc"); // "라"(wide) 조합 중
    const snap = overlay.compose(core.renderSnapshot());
    // 삽입형: '라'가 커서 자리(col2)에 들어가고 '나'(col2)·'다'(col4)는 조합 폭(2)만큼 오른쪽으로
    // 밀린다("가[라]나다"). 뒤 텍스트는 일반 intensity(dim 아님)라 고스트가 아니어서 밀린다.
    try std.testing.expectEqual(@as(u21, 0xAC00), snap.cells[0].codepoint); // 가(그대로)
    try std.testing.expectEqual(@as(u21, 0xB77C), snap.cells[2].codepoint); // 라(조합, 반전)
    try std.testing.expect(snap.cells[2].style.reverse);
    try std.testing.expectEqual(@as(u2, 2), snap.cells[2].width);
    try std.testing.expect(snap.cells[3].continuation);
    try std.testing.expectEqual(@as(u21, 0xB098), snap.cells[4].codepoint); // 나(오른쪽으로 밀림 col4)
    try std.testing.expect(snap.cells[5].continuation);
    try std.testing.expectEqual(@as(u21, 0xB2E4), snap.cells[6].codepoint); // 다(밀림 col6)
    try std.testing.expect(!snap.cursor.visible);
    try std.testing.expectEqual(@as(u16, 4), snap.cursor.col); // 커서는 조합 끝(col2+폭2)
    // 실제 그리드는 불변 — 확정 전까지 셸 상태는 "가나다" 그대로다.
    try std.testing.expectEqual(@as(u21, 0xB098), core.screen.cells[2].codepoint); // grid의 '나'는 col2
    try std.testing.expectEqual(@as(u21, 0xB2E4), core.screen.cells[4].codepoint); // grid의 '다'는 col4
}

test "preedit ambiguous-width=wide: circled number drawn 2 cells (width consistent with cursor advance)" {
    // 코드리뷰 결함 회귀: 공통 preedit 합성기가 cellWidthAmbiguous(2칸)가 아니라 cellWidth(1칸)로 그리면,
    // wide 모드에서 동그란 번호의 continuation이 안 그려지고 커서가 1칸 모자랐다. 폭 출처를 일치시킴.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    var overlay = @import("preedit.zig").Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    core.ambiguous_wide = true; // canonical base snapshot의 폭 정책을 overlay가 그대로 소비한다.
    try core.write("ab"); // 커서 col 2
    try core.write("\x1b[2D"); // 커서를 col 0으로(뒤 글자 위에서 조합)
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
    try overlay.replace("③"); // U+2462 — wide면 2칸
    const snap = overlay.compose(core.renderSnapshot());
    try std.testing.expectEqual(@as(u21, 0x2462), snap.cells[0].codepoint); // ③(조합)
    try std.testing.expectEqual(@as(u2, 2), snap.cells[0].width); // ambiguous-aware → 2칸
    try std.testing.expect(snap.cells[1].continuation); // continuation(잔상 'b'가 아님)
    try std.testing.expectEqual(@as(u16, 2), snap.cursor.col); // 조합 끝 = preedit_width(2)와 일치
    // 삽입형이라 'a'/'b'(일반 텍스트, dim 아님)는 ③ 뒤로 밀린다(col2/col3).
    try std.testing.expectEqual(@as(u21, 'a'), snap.cells[2].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), snap.cells[3].codepoint);
}

test "preedit overlays a trailing DIM autosuggest ghost (딱 고스트만 가림 — 옆으로 안 밀림)" {
    // Claude Code 등이 커서 뒤에 그린 인라인 자동완성 고스트는 faint(SGR 2)로 온다. 조합 중 이걸
    // 삽입형으로 밀면 잔상이 남으므로(앱 미전송이라 안 지워짐) dim 후행 run은 오버레이로 덮는다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    var overlay = @import("preedit.zig").Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try core.write("\x1b[2m\xec\x9d\x91\x1b[0m"); // faint(SGR 2)로 그린 고스트 "응"(wide, col0-1)
    try std.testing.expect(core.screen.cells[0].style.dim); // 고스트 base는 dim
    try core.write("\x1b[2D"); // 커서를 col0(고스트 위)으로
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);

    try overlay.replace("\xeb\x9d\xbc"); // "라"(wide) 조합 중
    const snap = overlay.compose(core.renderSnapshot());
    // '라'가 '응'을 덮는다(안 밀림) — dim 고스트라 예외.
    try std.testing.expectEqual(@as(u21, 0xB77C), snap.cells[0].codepoint); // 라(덮음)
    try std.testing.expect(snap.cells[0].style.reverse);
    try std.testing.expect(snap.cells[1].continuation);
    try std.testing.expectEqual(@as(u16, 2), snap.cursor.col); // 커서는 조합 끝
    try std.testing.expect(!snap.cursor.visible);
    // 실제 그리드의 고스트는 불변 — 확정 시 앱이 알아서 정리한다.
    try std.testing.expectEqual(@as(u21, 0xC751), core.screen.cells[0].codepoint); // grid엔 '응' 그대로
}

test "preedit inserts before NON-dim trailing text (일반 텍스트는 고스트 아님 — 밀린다)" {
    // 위 테스트의 대칭: 같은 후행 wide '응'이 dim이 아니면(일반 편집 텍스트) 고스트가 아니라 실
    // 텍스트로 보고 삽입형으로 민다. dim 한 플래그가 오버레이(고스트) vs 삽입(실 텍스트)을 가른다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    var overlay = @import("preedit.zig").Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try core.write("\xec\x9d\x91"); // 일반 intensity 텍스트 "응"(wide, col0-1) — dim 아님
    try std.testing.expect(!core.screen.cells[0].style.dim);
    try core.write("\x1b[2D"); // 커서를 col0으로
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);

    try overlay.replace("\xeb\x9d\xbc"); // "라"(wide) 조합 중
    const snap = overlay.compose(core.renderSnapshot());
    // '라'가 col0에 삽입되고 '응'은 col2로 밀린다(안 가려짐).
    try std.testing.expectEqual(@as(u21, 0xB77C), snap.cells[0].codepoint); // 라(조합)
    try std.testing.expect(snap.cells[1].continuation);
    try std.testing.expectEqual(@as(u21, 0xC751), snap.cells[2].codepoint); // 응(밀림 col2)
    try std.testing.expect(snap.cells[3].continuation);
    try std.testing.expectEqual(@as(u16, 2), snap.cursor.col); // 조합 끝
}

test "preedit overlay clears the orphan continuation when a narrow glyph covers a DIM wide ghost" {
    // 좁은 조합 글자(폭1)가 wide 고스트(폭2, faint)의 base만 덮으면 다음 칸 continuation이 짝을 잃는다.
    // dim 고스트라 오버레이 경로 — 짝 잃은 continuation을 비워 렌더가 base 없는 반쪽을 안 그리게 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    var overlay = @import("preedit.zig").Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try core.write("\x1b[2m\xec\x9d\x91\x1b[0m"); // faint 고스트 "응"(wide, col0 base + col1 continuation)
    try core.write("\x1b[2D"); // 커서를 col0으로
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);

    try overlay.replace("a"); // 폭1 조합 글자
    const snap = overlay.compose(core.renderSnapshot());
    try std.testing.expectEqual(@as(u21, 'a'), snap.cells[0].codepoint); // 'a'(조합, 폭1)
    try std.testing.expectEqual(@as(u2, 1), snap.cells[0].width);
    try std.testing.expect(!snap.cells[1].continuation); // 짝 잃은 continuation 정리됨(잔상 없음)
    try std.testing.expect(types.isUnwritten(snap.cells[1]));
    try std.testing.expectEqual(@as(u16, 1), snap.cursor.col); // 커서는 조합 끝
    try std.testing.expectEqual(@as(u21, 0xC751), core.screen.cells[0].codepoint); // grid의 '응' 불변
}

test "preedit clears the truncated wide base when the cursor sits on a continuation cell" {
    // 커서가 wide glyph의 continuation 칸(CUF/CHA로 가능)에 있을 때 조합하면, 그 칸만 밀리거나 덮여
    // 좌측 base가 짝 잃은 잘린 wide가 된다 — 비워서 base와 preedit이 겹쳐 그려지지 않게 한다(리뷰 발견).
    // 후행이 continuation 한 칸뿐이라 고스트 판정에 안 걸리고 삽입 경로를 타지만 정리는 동일하게 필요.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    var overlay = @import("preedit.zig").Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try core.write("\xec\x9d\x91"); // "응"(wide, col0 base + col1 continuation)
    try core.write("\x1b[2G"); // CHA col2(1-based) = col1(continuation 칸)
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.col);

    try overlay.replace("\xeb\x9d\xbc"); // "라"(wide) 조합 중
    const snap = overlay.compose(core.renderSnapshot());
    try std.testing.expect(types.isUnwritten(snap.cells[0])); // 잘린 '응' base 정리됨
    try std.testing.expectEqual(@as(u21, 0xB77C), snap.cells[1].codepoint); // 라(조합, col1)
    try std.testing.expectEqual(@as(u2, 2), snap.cells[1].width);
    try std.testing.expect(snap.cells[2].continuation);
    try std.testing.expectEqual(@as(u16, 3), snap.cursor.col); // 조합 끝
    try std.testing.expectEqual(@as(u21, 0xC751), core.screen.cells[0].codepoint); // grid의 '응' 불변
}

test "zsh wide-glyph erase sequence (BS BS SP SP BS BS) cleans the hangul cell pair" {
    // 실제 zsh 캡처: "ls 안"에서 Backspace 1회에 zsh가 보내는 시퀀스는 "\x08\x08  \x08\x08".
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("ls \xec\x95\x88"); // "ls 안" — 안은 col3(wide)+col4(continuation)
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[3].width);
    try core.write("\x08\x08  \x08\x08");
    // 한글이 지워지고 "ls "만 남는다 — continuation 잔재 없이.
    try std.testing.expectEqual(@as(u21, ' '), core.screen.cells[3].codepoint);
    try std.testing.expectEqual(@as(u21, ' '), core.screen.cells[4].codepoint);
    try std.testing.expect(!core.screen.cells[4].continuation);
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.col);
}

test "OSC 8 pen_link resets on alt-screen switch and RIS (no stale clickable cells)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    // 링크를 열고 닫지 않은 채(악성/부분 출력) 글자 출력 — 그 글자엔 링크가 찍힌다.
    try core.write("\x1b]8;;https://x.yz\x1b\\ab");
    try std.testing.expect(core.screen.cells[0].link != 0);

    // alt 진입: pen_link이 리셋돼 alt에서 출력한 글자엔 링크가 안 찍힌다.
    try core.write("\x1b[?1049h");
    try core.write("Z");
    try std.testing.expectEqual(@as(u32, 0), core.screen.cells[0].link); // alt 화면 cell
    try std.testing.expectEqual(@as(u32, 0), core.pen_link);

    // primary 복귀도 pen_link 0.
    try core.write("\x1b[?1049l");
    try std.testing.expectEqual(@as(u32, 0), core.pen_link);

    // 다시 링크 열고 RIS(ESC c) — 저장소가 비고 화면/스크롤백/링크가 초기화된다.
    try core.write("\x1b]8;;https://a.bc\x1b\\q\r\nr");
    try std.testing.expect(core.link_store.items.len >= 1);
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(@as(usize, 0), core.link_store.items.len);
    try std.testing.expectEqual(@as(u32, 0), core.pen_link);
    try std.testing.expect(types.isUnwritten(core.screen.cells[0])); // 화면 비움
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // 스크롤백 비움
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col);
}

test "emoji grapheme: skin tone modifier and flag (RI pair) cluster into one wide cell" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();

    // 스킨톤 modifier(🏽 U+1F3FD)는 EAW Wide(2)라 별도 셀로 둔다 — zsh의 ZLE 너비(👍2+🏽2=4)와
    // 일치시켜 붙여넣기 redraw가 안 깨지게(너비 합의). 👍는 col0-1, 🏽는 col2-3.
    try core.write("\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd");
    try std.testing.expectEqual(@as(u21, 0x1F44D), core.screen.cells[0].codepoint);
    try expectCluster(&core, core.screen.cells[0].grapheme_id, &.{}); // 클러스터 안 함
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[0].width);
    try std.testing.expectEqual(@as(u21, 0x1F3FD), core.screen.cells[2].codepoint); // 스킨톤은 별도 셀
    try std.testing.expectEqual(@as(u16, 4), core.screen.cursor.col); // 4칸(zsh와 일치)

    // 국기 RI(🇰🇷 = U+1F1F0 U+1F1F7)는 zsh와 같이 낱자(각 width 1)로 둔다 — 클러스터하면
    // 우리는 width-2 한 셀, zsh는 width-1 둘이라 구조가 달라 붙여넣기 redraw가 깨졌다.
    try core.write("\r\n\xf0\x9f\x87\xb0\xf0\x9f\x87\xb7");
    try std.testing.expectEqual(@as(u21, 0x1F1F0), core.screen.cells[10].codepoint);
    try std.testing.expectEqual(@as(u2, 1), core.screen.cells[10].width); // RI = width 1(EAW Neutral)
    try std.testing.expectEqual(@as(u21, 0x1F1F7), core.screen.cells[11].codepoint); // 둘째 RI 별도 셀
    try expectCluster(&core, core.screen.cells[10].grapheme_id, &.{});
}

test "mode 2027: VS16 promotes to width 2 only when grapheme cluster mode is on" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    // 기본(2027 off): ❤+VS16 = width 1(EAW, zsh 일치).
    try core.write("\xe2\x9d\xa4\xef\xb8\x8f"); // ❤️
    try std.testing.expectEqual(@as(u2, 1), core.screen.cells[0].width);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.col);

    // 2027 on: 풀사이즈 width 2.
    try core.write("\r\n\x1b[?2027h\xe2\x9d\xa4\xef\xb8\x8f");
    try std.testing.expect(core.grapheme_cluster_mode);
    try std.testing.expectEqual(@as(u21, 0x2764), core.screen.cells[10].codepoint);
    try expectCluster(&core, core.screen.cells[10].grapheme_id, &.{0xFE0F});
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[10].width);
    try std.testing.expect(core.screen.cells[11].continuation);
}

test "emoji_wide promotes VS16/keycap to width 2 without mode 2027 (text.emoji-width=wide)" {
    // 사용자 피드백: TUI(Claude Code)가 mode 2027을 안 켜서 키캡 2️⃣가 1칸에 욱여넣어져 작게 나옴.
    // text.emoji-width=wide(emoji_wide)면 2027 합의 없이도 base+VS16을 width 2로 승격해 풀사이즈로 그린다
    // (Ghostty/iTerm2·모던 TUI string-width와 정합). advance도 2 — 1칸짜리 작은 이모지 + 빈틈을 푼다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    core.emoji_wide = true; // app_session이 config(text.emoji-width=wide 기본)에서 켜는 값
    try std.testing.expect(!core.grapheme_cluster_mode); // 2027 없이도

    // ❤+VS16 = ❤️ → width 2 + continuation.
    try core.write("\xe2\x9d\xa4\xef\xb8\x8f");
    try std.testing.expectEqual(@as(u21, 0x2764), core.screen.cells[0].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[0].width);
    try std.testing.expect(core.screen.cells[1].continuation);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col); // advance 2

    // 키캡 2️⃣ = '2'(0x32) + VS16(FE0F) + 엔클로징 키캡(U+20E3) → base 승격(FE0F가 트리거).
    try core.write("\r\n\x32\xef\xb8\x8f\xe2\x83\xa3");
    try std.testing.expectEqual(@as(u21, 0x32), core.screen.cells[10].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[10].width);
    try std.testing.expect(core.screen.cells[11].continuation);

    // 대조: emoji_wide=false면 같은 ❤️가 width 1 유지(zsh 정렬 보호 — 기존 동작).
    var narrow = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer narrow.deinit();
    try narrow.write("\xe2\x9d\xa4\xef\xb8\x8f");
    try std.testing.expectEqual(@as(u2, 1), narrow.screen.cells[0].width);
}

test "emoji_wide: 스킨톤·ZWJ·국기가 mode 2027 없이도 한 셀로 묶인다 (text.emoji-width=wide)" {
    // 회귀 고정(2026-08-20 사용자 제보): 같은 설정에서 ❤+VS16 은 2칸으로 묶이는데 👨‍👩‍👧‍👦 는 구성 이모지마다
    // 셀을 먹어 **10칸**이 됐다. 실측 `|👍🏽|`=3.8칸 · `|👨‍👩‍👧‍👦|`=10.4칸(같은 줄의 `|❤️|`·`|🇰🇷|`·`|人|`은 2칸).
    // 모던 TUI(Ink 기반 앱)는 cluster 단위로 폭을 세므로 그 앱의 표·박스가 밀렸다.
    //
    // VS16 승격이 이미 `emoji_wide` 로 열려 있었는데(바로 위 테스트) cluster 흡수만 2027 게이트에 남아
    // 있던 것이 원인이다. 둘의 게이트를 맞춘다 — Ghostty 도 `grapheme-width-method` 가 기본 `unicode` 라
    // 2027 없이 cluster 단위로 센다. `text.emoji-width=narrow` 면 옛 동작(아래 테스트)이 남는다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 4 });
    defer core.deinit();
    core.emoji_wide = true; // app_session 이 config(text.emoji-width=wide 기본)에서 켜는 값
    try std.testing.expect(!core.grapheme_cluster_mode); // 2027 없이도

    // 스킨톤: 👍🏽 한 셀 width 2(modifier 가 별도 셀을 안 먹는다).
    try core.write("\u{1F44D}\u{1F3FD}");
    try std.testing.expectEqual(@as(u21, 0x1F44D), core.screen.cells[0].codepoint);
    try expectCluster(&core, core.screen.cells[0].grapheme_id, &.{0x1F3FD});
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[0].width);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);

    // ZWJ 가족: 👨‍👩‍👧 한 셀 width 2(구성 이모지마다 셀을 먹지 않는다 — 이 회귀의 핵심).
    try core.write("\r\n\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}");
    try std.testing.expectEqual(@as(u21, 0x1F468), core.screen.cells[12].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[12].width);
    try expectCluster(&core, core.screen.cells[12].grapheme_id, &.{ 0x200D, 0x1F469, 0x200D, 0x1F467 });
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);

    // 국기: 🇰🇷 한 셀 width 2(RI 쌍).
    try core.write("\r\n\u{1F1F0}\u{1F1F7}");
    try std.testing.expectEqual(@as(u21, 0x1F1F0), core.screen.cells[24].codepoint);
    try expectCluster(&core, core.screen.cells[24].grapheme_id, &.{0x1F1F7});
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[24].width);

    // dump 무손실 — 묶어도 원본 시퀀스가 복원된다(클립보드·재출력).
    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}") != null);
}

test "mode 2027: skin tone and flags cluster only when on" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?2027h");
    // 스킨톤: 👍🏽 한 셀 width 2.
    try core.write("\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd");
    try std.testing.expectEqual(@as(u21, 0x1F44D), core.screen.cells[0].codepoint);
    try expectCluster(&core, core.screen.cells[0].grapheme_id, &.{0x1F3FD});
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);
    // 국기: 🇰🇷 한 셀 width 2.
    try core.write("\xf0\x9f\x87\xb0\xf0\x9f\x87\xb7");
    try std.testing.expectEqual(@as(u21, 0x1F1F0), core.screen.cells[2].codepoint);
    try expectCluster(&core, core.screen.cells[2].grapheme_id, &.{0x1F1F7});
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[2].width);

    // 2027 off면 스킨톤은 별도 셀(EAW Wide).
    try core.write("\x1b[?2027l\r\n\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd");
    try expectCluster(&core, core.screen.cells[12].grapheme_id, &.{});
    try std.testing.expectEqual(@as(u21, 0x1F3FD), core.screen.cells[14].codepoint); // 별도 셀
}

test "emoji ZWJ 시퀀스(GB11): 가족 이모지가 mode 2027에서 한 셀(폭 2)로 묶인다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?2027h");
    // 👨‍👩‍👧 = 👨(1F468) ZWJ 👩(1F469) ZWJ 👧(1F467). ZWJ로 이어진 가족은 한 글자(폭 2)다.
    try core.write("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}");
    const s = core.snapshot();
    try std.testing.expectEqual(@as(u16, 2), s.cursor.col); // 한 글자 = 2칸
    try std.testing.expectEqual(@as(u21, 0x1F468), s.cells[0].codepoint); // base
    try std.testing.expectEqual(@as(u2, 2), s.cells[0].width);
    try std.testing.expect(s.cells[1].continuation);
    try std.testing.expect(s.cells[0].grapheme_id != 0);
    try expectCluster(&core, s.cells[0].grapheme_id, &.{ 0x200D, 0x1F469, 0x200D, 0x1F467 });

    // dump 무손실: 전체 ZWJ 시퀀스가 복원된다(클립보드·재출력 — 잘림 금지).
    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}") != null);

    // 2027 off면 ZWJ가 안 묶여 별도 셀(가족이 흩어짐 — 앱과 폭 합의 없음).
    try core.write("\x1b[?2027l\r\n\u{1F468}\u{200D}\u{1F469}");
    try std.testing.expectEqual(@as(u21, 0x1F468), core.screen.cells[8].codepoint);
    try expectCluster(&core, core.screen.cells[8].grapheme_id, &.{}); // 묶지 않음
}

test "emoji ZWJ + 스킨톤: 사람마다 스킨톤이 다른 가족도 한 셀로 (통합 경로)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[?2027h");
    // 🧑🏻‍🤝‍🧑🏽 = 🧑(1F9D1) 🏻(1F3FB) ZWJ 🤝(1F91D) ZWJ 🧑(1F9D1) 🏽(1F3FD).
    // 둘째 사람의 스킨톤(🏽)은 grapheme_id가 이미 있는 cluster에 붙는다 — lone 제한 없이 흡수돼야
    // 가족 전체가 한 셀로 모인다(통합 경로의 핵심: skin-tone이 non-lone 그림문자 cluster에도 붙음).
    try core.write("\u{1F9D1}\u{1F3FB}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}\u{1F3FD}");
    const s = core.snapshot();
    try std.testing.expectEqual(@as(u16, 2), s.cursor.col); // 한 글자 = 2칸
    try std.testing.expectEqual(@as(u21, 0x1F9D1), s.cells[0].codepoint);
    try expectCluster(&core, s.cells[0].grapheme_id, &.{ 0x1F3FB, 0x200D, 0x1F91D, 0x200D, 0x1F9D1, 0x1F3FD });
}

test "emoji 통합 경로 엣지: 스킨톤은 폭 2 base에만·ZWJ는 RI base에 안 붙는다 (회귀 가드)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?2027h");

    // (1) 좁은 그림문자(❤ U+2764, 폭 1)에 스킨톤이 붙으면 안 된다 — Fitzpatrick은 Emoji_Modifier_Base(폭 2)
    // 에만 유효하다. 붙이면 promoteLastToEmojiWidth가 ❤를 1→2로 잘못 늘렸다(malformed 입력). 스킨톤은 제 셀로.
    try core.write("\u{2764}\u{1F3FD}"); // ❤ + 🏽
    try std.testing.expectEqual(@as(u21, 0x2764), core.screen.cells[0].codepoint);
    try std.testing.expectEqual(@as(u2, 1), core.screen.cells[0].width); // 1 유지(승격 안 됨)
    try expectCluster(&core, core.screen.cells[0].grapheme_id, &.{}); // 스킨톤 흡수 안 함
    try std.testing.expectEqual(@as(u21, 0x1F3FD), core.screen.cells[1].codepoint); // 스킨톤 별도 셀

    // (2) 짝 안 찬 국기(반쪽 RI 🇰 U+1F1F0, 폭 1) 뒤 ZWJ는 흡수되면 안 된다 — 유효한 emoji 시퀀스에
    // flag+ZWJ 없음. RI는 GB12/13(다음 RI와 짝)만 따르고 ZWJ(GB11)에 안 낚인다.
    try core.write("\r\n\u{1F1F0}\u{200D}"); // 🇰(lone RI) + ZWJ
    try std.testing.expectEqual(@as(u21, 0x1F1F0), core.screen.cells[12].codepoint);
    try std.testing.expectEqual(@as(u2, 1), core.screen.cells[12].width); // 1 유지
    try expectCluster(&core, core.screen.cells[12].grapheme_id, &.{}); // ZWJ 흡수 안 함
    try std.testing.expectEqual(@as(u21, 0x200D), core.screen.cells[13].codepoint); // ZWJ 별도 셀
}

test "DECRQM reports mode 2027 state so apps can detect support" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    // 미설정: reset이지만 인식함(2) — 앱이 지원을 감지하고 켤 수 있다.
    try core.write("\x1b[?2027$p");
    try std.testing.expectEqualStrings("\x1b[?2027;2$y", core.pendingResponse());
    core.clearResponse();
    // 켠 뒤: set(1).
    try core.write("\x1b[?2027h\x1b[?2027$p");
    try std.testing.expectEqualStrings("\x1b[?2027;1$y", core.pendingResponse());
    core.clearResponse();
    // 모르는 모드: 미인식(0).
    try core.write("\x1b[?9999$p");
    try std.testing.expectEqualStrings("\x1b[?9999;0$y", core.pendingResponse());
}

test "synchronized output (DECSET 2026): set/reset + DECRQM 지원 감지" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try std.testing.expect(!core.sync_output); // 기본 off
    try std.testing.expectEqual(@as(u64, 0), core.sync_bsu_count); // 리더 transition 카운터 기본 0
    try std.testing.expectEqual(@as(u64, 0), core.sync_esu_count);
    try core.write("\x1b[?2026h"); // BSU
    try std.testing.expect(core.sync_output);
    try std.testing.expectEqual(@as(u64, 1), core.sync_bsu_count); // BSU(set)에서 bsu만 증가
    try std.testing.expectEqual(@as(u64, 0), core.sync_esu_count);
    try core.write("\x1b[?2026l"); // ESU
    try std.testing.expect(!core.sync_output);
    try std.testing.expectEqual(@as(u64, 1), core.sync_bsu_count); // ESU(reset)에서 esu만 증가(.sync 로거가 짝으로 노출)
    try std.testing.expectEqual(@as(u64, 1), core.sync_esu_count);
    // DECRQM: 미설정=reset(2, 인식 — 앱이 지원 감지), 켜면 set(1).
    try core.write("\x1b[?2026$p");
    try std.testing.expectEqualStrings("\x1b[?2026;2$y", core.pendingResponse());
    core.clearResponse();
    try core.write("\x1b[?2026h\x1b[?2026$p");
    try std.testing.expectEqualStrings("\x1b[?2026;1$y", core.pendingResponse());
}

test "synchronized output (2026): 조각난 write에도 재조립 (SSH fragmentation 가설 검증)" {
    // maru ssh 원격에서 SSH가 바이트 스트림을 임의 경계로 쪼개 전달하므로, ESC[?2026h/l가 write 중간에
    // 잘려 도착할 수 있다. 파서 상태(self.parser)가 TerminalCore에 persist하는 resumable 상태머신이라
    // **모든 split 경계에서 재조립**돼 sync 토글·리더 카운터가 정확해야 한다 — 안 그러면 sync_output이
    // stuck돼 원격 화면이 영구 desync(§11.6 미해결 이슈의 "파싱 fragmentation" 가설). 이 테스트가 통과하면
    // 파싱은 무죄이고 desync는 리더↔메인 타이밍(투영 게이트) 문제로 좁혀진다.
    const bsu = "\x1b[?2026h";
    const esu = "\x1b[?2026l"; // esu.len == bsu.len(8) — 같은 split 재사용
    // 2조각 split: 모든 경계 1..len-1에서 앞/뒤를 별도 write로 쪼갠다.
    var split: usize = 1;
    while (split < bsu.len) : (split += 1) {
        var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
        defer core.deinit();
        try core.write(bsu[0..split]);
        try core.write(bsu[split..]);
        try std.testing.expect(core.sync_output); // BSU 재조립 → hold on
        try std.testing.expectEqual(@as(u64, 1), core.sync_bsu_count);
        try core.write(esu[0..split]);
        try core.write(esu[split..]);
        try std.testing.expect(!core.sync_output); // ESU 재조립 → hold off
        try std.testing.expectEqual(@as(u64, 1), core.sync_esu_count);
    }
    // 극단: 바이트-단위 write(한 write=1바이트) — SSH가 최소 조각으로 흘려도 재조립돼야 한다.
    {
        var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
        defer core.deinit();
        for (bsu) |b| try core.write(&[_]u8{b});
        try std.testing.expect(core.sync_output);
        try std.testing.expectEqual(@as(u64, 1), core.sync_bsu_count);
        for (esu) |b| try core.write(&[_]u8{b});
        try std.testing.expect(!core.sync_output);
        try std.testing.expectEqual(@as(u64, 1), core.sync_esu_count);
    }
}

test "kitty FlagStack: push/pop/set/overflow (audit 4/5)" {
    var stack: KittyFlagStack = .{};
    try std.testing.expectEqual(KittyFlags{}, stack.current()); // 기본 disabled

    stack.push(.{ .disambiguate = true }); // CSI > 1 u
    try std.testing.expectEqual(KittyFlags{ .disambiguate = true }, stack.current());
    stack.push(.{ .report_events = true }); // 새 레벨 push
    try std.testing.expectEqual(KittyFlags{ .report_events = true }, stack.current());
    stack.pop(1); // CSI < 1 u → 이전 레벨 복원
    try std.testing.expectEqual(KittyFlags{ .disambiguate = true }, stack.current());

    stack.set(.@"or", .{ .report_events = true }); // CSI = ; 2 u 합집합
    try std.testing.expect(stack.current().disambiguate and stack.current().report_events);
    stack.set(.not, .{ .report_events = true }); // CSI = ; 3 u 차집합
    try std.testing.expect(stack.current().disambiguate and !stack.current().report_events);
    stack.set(.set, .{ .report_all = true }); // CSI = ; 1 u 치환
    try std.testing.expectEqual(KittyFlags{ .report_all = true }, stack.current());

    stack.pop(100); // 과도한 pop = 전체 리셋(DoS 회피)
    try std.testing.expectEqual(KittyFlags{}, stack.current());
}

test "kitty Flags: packed bit order matches kitty spec (LSB=disambiguate)" {
    try std.testing.expectEqual(@as(u5, 0b00001), (KittyFlags{ .disambiguate = true }).int());
    try std.testing.expectEqual(@as(u5, 0b00010), (KittyFlags{ .report_events = true }).int());
    try std.testing.expectEqual(@as(u5, 0b00100), (KittyFlags{ .report_alternates = true }).int());
    try std.testing.expectEqual(@as(u5, 0b01000), (KittyFlags{ .report_all = true }).int());
    try std.testing.expectEqual(@as(u5, 0b10000), (KittyFlags{ .report_associated = true }).int());
}

test "kitty keyboard CSI u dispatch: push(>)/set(=)/query(?)/pop(<)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try std.testing.expectEqual(KittyFlags{}, core.kitty_flags.current()); // 기본 disabled

    try core.write("\x1b[>1u"); // push disambiguate
    try std.testing.expect(core.kitty_flags.current().disambiguate);
    try core.write("\x1b[?u"); // query → CSI ? 1 u
    try std.testing.expectEqualStrings("\x1b[?1u", core.pendingResponse());
    core.clearResponse();

    // 미구현 flag는 마스킹된다(거짓 광고 방지): =2;2u(or report_events)는 report_events를 안 켜고
    // disambiguate만 유지한다 — Maru는 disambiguate 수준만 인코딩하기 때문.
    try core.write("\x1b[=2;2u");
    try std.testing.expect(core.kitty_flags.current().disambiguate);
    try std.testing.expect(!core.kitty_flags.current().report_events);

    try core.write("\x1b[<1u"); // pop → 이전 레벨(disabled)
    try std.testing.expectEqual(KittyFlags{}, core.kitty_flags.current());
    // RIS는 스택을 비활성으로 리셋한다.
    try core.write("\x1b[>9u\x1bc");
    try std.testing.expectEqual(KittyFlags{}, core.kitty_flags.current());
}

test "kitty keyboard query는 미구현 flag를 활성으로 거짓 보고하지 않는다 (audit HIGH)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    // 앱이 report_events(>2u)만 켜려 하면 — Maru는 미구현이라 스택에 저장하지 않고, query는 0(비활성)을
    // 보고한다. 예전엔 2를 그대로 저장·보고해 "report_events 활성"이라 거짓 광고했다(인코딩은 disambiguate만).
    try core.write("\x1b[>2u\x1b[?u");
    try std.testing.expectEqualStrings("\x1b[?0u", core.pendingResponse());
    core.clearResponse();
    // disambiguate는 지원하므로 보고된다 — 9(=disambiguate 1 + report_all 8)를 켜도 미구현 비트는 떨구고 1만.
    try core.write("\x1b[>9u\x1b[?u");
    try std.testing.expectEqualStrings("\x1b[?1u", core.pendingResponse());
}

test "APC (ESC _ ... ESC \\): kitty graphics payload가 화면에 텍스트로 새지 않는다 (graphics 토대)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();
    // kitty graphics APC — control+payload가 셀에 안 찍히고 소비된다(과거 ESC_ 미처리면 누수).
    try core.write("\x1b_Ga=T,f=32;AAAA\x1b\\");
    try std.testing.expect(types.isUnwritten(core.screen.cells[0])); // 텍스트 누수 없음
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.col); // 커서 안 움직임
    // APC 종료(ESC \) 후 일반 텍스트는 정상 — ground 복귀 확인.
    try core.write("hi");
    try std.testing.expectEqual(@as(u21, 'h'), core.screen.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'i'), core.screen.cells[1].codepoint);
}

test "kitty graphics command 파싱: control k=v 주요 key (audit 5/5b)" {
    // a=T(transmit+display), f=32(RGBA), s/v 픽셀 크기, i image id, m=1 chunked, o=z compression.
    const cmd = parser.parseKittyGraphicsCommand("a=T,f=32,s=100,v=50,i=3,m=1,o=z");
    try std.testing.expectEqual(@as(u8, 'T'), cmd.action);
    try std.testing.expectEqual(@as(u16, 32), cmd.format);
    try std.testing.expectEqual(@as(u32, 100), cmd.width);
    try std.testing.expectEqual(@as(u32, 50), cmd.height);
    try std.testing.expectEqual(@as(u32, 3), cmd.image_id);
    try std.testing.expect(cmd.more);
    try std.testing.expectEqual(@as(u8, 'z'), cmd.compression);
}

test "kitty graphics command 파싱: 기본값 + payload(';' 다음)는 control에서 제외" {
    const q = parser.parseKittyGraphicsCommand("a=q;AAAAdata");
    try std.testing.expectEqual(@as(u8, 'q'), q.action); // query
    try std.testing.expectEqual(@as(u16, 32), q.format); // 기본 RGBA — payload는 파싱 안 함
    const empty = parser.parseKittyGraphicsCommand("");
    try std.testing.expectEqual(@as(u8, 't'), empty.action); // 기본 transmit(견고성)
}

test "kitty graphics transmit: RGBA 저장 + 같은 id 교체 + delete (audit 5/5-1단계)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();

    // 2x2 RGBA = 16바이트(0xAB)를 base64로 인코딩해 transmit(a=t, f=32, s=2, v=2, i=7).
    const raw = [_]u8{0xAB} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    try std.testing.expect(core.kitty_images.map.contains(7));
    const img = core.kitty_images.map.get(7).?;
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    try std.testing.expectEqual(@as(u8, 4), img.bpp);
    try std.testing.expectEqual(@as(usize, 16), img.data.len);
    try std.testing.expectEqual(@as(u8, 0xAB), img.data[0]); // base64 디코드 정확
    try std.testing.expectEqual(@as(usize, 16), core.kitty_images.total_bytes);

    // 같은 id(7)로 다시 transmit → 교체(total_bytes 누적 안 됨).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    try std.testing.expectEqual(@as(usize, 16), core.kitty_images.total_bytes);

    // delete(a=d, d=I, i=7) → 이미지 데이터까지 제거(대문자 I). d 기본값은 'a'(전체)라 image_id 지정 삭제는 d=I.
    try core.write("\x1b_Ga=d,d=I,i=7\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(7));
    try std.testing.expectEqual(@as(usize, 0), core.kitty_images.total_bytes);
}

test "kitty graphics transmit: 크기 불일치·PNG·zlib는 저장 안 함, RIS는 비운다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    var seq: [80]u8 = undefined;

    // 크기 불일치(s=2,v=2,f=32 → 16바이트 기대인데 4바이트만) → 거부.
    const small = [_]u8{1} ** 4;
    var sb: [16]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&sb, &small)}));
    try std.testing.expect(!core.kitty_images.map.contains(1));
    // 과대 치수(s/v=u32max)는 곱이 usize를 넘어 — panic 없이 거부한다(code review 발견).
    try core.write("\x1b_Ga=t,f=32,s=4294967295,v=4294967295,i=8;AAAA\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(8));
    // PNG(f=100)·zlib(o=z)은 후속이라 저장 안 함.
    try core.write("\x1b_Ga=t,f=100,s=2,v=2,i=2;AAAA\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(2));
    try core.write("\x1b_Ga=t,f=32,s=2,v=2,i=3,o=z;AAAA\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(3));

    // 정상 저장 후 RIS(ESC c)는 전부 비운다.
    const raw = [_]u8{2} ** 16;
    var b64: [32]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=9;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&b64, &raw)}));
    try std.testing.expect(core.kitty_images.map.contains(9));
    try core.write("\x1bc");
    try std.testing.expect(!core.kitty_images.map.contains(9));
    try std.testing.expectEqual(@as(usize, 0), core.kitty_images.total_bytes);
}

// --- kitty graphics K1: placement(코어) — 저장/노출/생애주기 ---

test "kitty graphics display(a=p): 커서 셀에 placement 생성 + 모든 display 키 파싱 + 뷰포트 매핑 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();

    // 2x2 RGBA 이미지(i=7) 전송(표시 안 함) — transmit만으론 placement가 안 생긴다.
    const raw = [_]u8{0xCD} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);

    // 커서를 (행1,열2)로 옮기고(CUP 2;3) display(a=p)로 표시 — 모든 display 키를 함께 검증.
    try core.write("\x1b[2;3H");
    try core.write("\x1b_Ga=p,i=7,p=5,c=3,r=2,z=-1,X=4,Y=6,x=1,y=2,w=8,h=9,C=1\x1b\\");

    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    const p = core.kitty_placements.items[0];
    try std.testing.expectEqual(@as(u32, 7), p.image_id);
    try std.testing.expectEqual(@as(u32, 5), p.placement_id);
    try std.testing.expectEqual(@as(usize, 1), p.anchor_row); // sb_count(0)+cursor.row(1)
    try std.testing.expectEqual(@as(u16, 2), p.anchor_col);
    try std.testing.expectEqual(@as(u32, 3), p.columns);
    try std.testing.expectEqual(@as(u32, 2), p.rows);
    try std.testing.expectEqual(@as(i32, -1), p.z);
    try std.testing.expectEqual(@as(u32, 4), p.cell_x_offset);
    try std.testing.expectEqual(@as(u32, 6), p.cell_y_offset);
    try std.testing.expectEqual(@as(u32, 1), p.src_x);
    try std.testing.expectEqual(@as(u32, 2), p.src_y);
    try std.testing.expectEqual(@as(u32, 8), p.src_width);
    try std.testing.expectEqual(@as(u32, 9), p.src_height);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row); // C=1 → 커서 안 움직임

    // renderSnapshot(바닥)은 뷰포트 상대 placement를 노출(top_abs=sb_count=0 → row=anchor=1).
    const snap = core.renderSnapshot();
    try std.testing.expectEqual(@as(usize, 1), snap.placements.len);
    try std.testing.expectEqual(@as(i32, 1), snap.placements[0].row);
    try std.testing.expectEqual(@as(u16, 2), snap.placements[0].col);
    try std.testing.expectEqual(@as(u32, 7), snap.placements[0].image_id);
    try std.testing.expectEqual(@as(i32, -1), snap.placements[0].z);
}

test "kitty graphics display(a=T): transmit+display 한 command로 이미지+placement (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0x10} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=4,c=2,r=1;{s}\x1b\\", .{b64s}));
    try std.testing.expect(core.kitty_images.map.contains(4)); // 저장
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len); // 표시
    try std.testing.expectEqual(@as(u32, 4), core.kitty_placements.items[0].image_id);
}

test "kitty graphics display: 없는 이미지/ i=0은 placement를 만들지 않는다 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b_Ga=p,i=99\x1b\\"); // 전송된 적 없는 이미지
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
    try core.write("\x1b_Ga=p\x1b\\"); // i 없음(0)
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
}

test "kitty graphics placement: (image_id,placement_id) 같으면 교체, 다르면 별개 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0x22} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    try core.write("\x1b_Ga=p,i=7,p=1,z=1\x1b\\");
    try core.write("\x1b_Ga=p,i=7,p=1,z=2\x1b\\"); // 같은 키 → 교체
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    try std.testing.expectEqual(@as(i32, 2), core.kitty_placements.items[0].z); // 갱신

    try core.write("\x1b_Ga=p,i=7,p=2\x1b\\"); // 다른 placement_id → 별개
    try std.testing.expectEqual(@as(usize, 2), core.kitty_placements.items.len);
}

test "kitty graphics display: 커서 이동 정책(C, r) (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 6 });
    defer core.deinit();
    const raw = [_]u8{0x33} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));

    // 기본(C 없음) + r=2 → 커서가 r만큼 아래로(행0 → 행2).
    try core.write("\x1b[1;1H\x1b_Ga=p,i=1,r=2\x1b\\");
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row);
    // r 미지정 + 셀 메트릭 미주입(이 테스트는 setCellMetrics를 안 부른다) → 환산 불가로 이동 안 함(K1 fallback).
    try core.write("\x1b[1;1H\x1b_Ga=p,i=1\x1b\\");
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    // C=1 → r이 있어도 이동 안 함.
    try core.write("\x1b[1;1H\x1b_Ga=p,i=1,r=3,C=1\x1b\\");
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row);
    // 화면 끝을 넘기는 이동은 스크롤 없이 마지막 행(rows-1=5)으로 clamp.
    try core.write("\x1b[5;1H\x1b_Ga=p,i=1,r=10\x1b\\"); // 행4 +10 → clamp 5
    try std.testing.expectEqual(@as(u16, 5), core.screen.cursor.row);
}

test "kitty graphics delete: 이미지와 그 placement를 함께 제거 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0x44} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=7,p=1\x1b\\");
    try core.write("\x1b_Ga=p,i=7,p=2\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), core.kitty_placements.items.len);

    try core.write("\x1b_Ga=d,d=I,i=7\x1b\\"); // 대문자 I = 이미지 7 + 그 모든 placement 제거
    try std.testing.expect(!core.kitty_images.map.contains(7));
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
}

test "kitty graphics placement: RIS는 placement를 비운다 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0x55} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=7\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
}

test "kitty graphics placement: 스크롤백 eviction에 따라 anchor 보정·제거 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    core.screen.sb.cap = 2; // 작은 스크롤백으로 eviction을 빨리 유발
    const raw = [_]u8{0x66} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    // 활성 행0에 표시 → anchor 절대 행 0.
    try core.write("\x1b[1;1H\x1b_Ga=p,i=7,p=1\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items[0].anchor_row);

    // 개행 3번 → 스크롤백이 가득(sb_count=2)차지만 eviction 전이라 anchor(절대 0) 유지.
    try core.write("\n\n\n");
    try std.testing.expectEqual(@as(usize, 2), core.screen.sb.count);
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items[0].anchor_row);

    // 한 번 더 → 가장 오래된 행 eviction → 화면 밖이 된 anchor 0 placement 제거.
    try core.write("\n");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
}

test "kitty graphics placement: 위로 스크롤하면 뷰포트 상대 row로 환산 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    const raw = [_]u8{0x77} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    // 행0에 표시(anchor abs 0). 개행으로 스크롤백 2줄 쌓아 placement가 활성 화면 위로 올라가게.
    try core.write("\x1b[1;1H\x1b_Ga=p,i=7\x1b\\");
    try core.write("\n\n\n"); // sb_count=2, anchor 0 유지(default max_scrollback이라 eviction 없음)
    try std.testing.expectEqual(@as(usize, 2), core.screen.sb.count);

    // 바닥에서는 anchor abs0가 top_abs(=sb_count=2) 위라 row=-2(화면 밖, 렌더러가 클립).
    try std.testing.expectEqual(@as(i32, -2), core.renderSnapshot().placements[0].row);

    // 맨 위까지 스크롤(view_offset=2) → top_abs=0 → row=0(보임).
    core.scrollViewport(2);
    const snap = core.renderSnapshot();
    try std.testing.expectEqual(@as(usize, 1), snap.placements.len);
    try std.testing.expectEqual(@as(i32, 0), snap.placements[0].row);
    try std.testing.expectEqual(@as(u16, 0), snap.placements[0].col);
}

// --- kitty graphics K2a: 이미지 픽셀 노출 + upload generation(코어) ---

test "kitty graphics images: transmit이 RenderSnapshot.images로 픽셀·치수·generation 노출 (K2a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0x9A} ** 16; // 2x2 RGBA
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    const snap = core.renderSnapshot();
    try std.testing.expectEqual(@as(usize, 1), snap.images.len);
    const v = snap.images[0];
    try std.testing.expectEqual(@as(u32, 7), v.image_id);
    try std.testing.expectEqual(@as(u32, 2), v.width);
    try std.testing.expectEqual(@as(u32, 2), v.height);
    try std.testing.expectEqual(@as(u8, 4), v.bpp);
    try std.testing.expectEqual(@as(usize, 16), v.pixels.len);
    try std.testing.expectEqual(@as(u8, 0x9A), v.pixels[0]); // zero-copy로 storage 픽셀
    try std.testing.expect(v.generation > 0);
}

test "kitty graphics images: 같은 id 재transmit은 generation을 올린다(렌더러 재업로드 신호) (K2a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    const gen1 = core.renderSnapshot().images[0].generation;
    // 같은 id로 다시 transmit → generation 증가(같은 id 교체여도 새 값).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    const gen2 = core.renderSnapshot().images[0].generation;
    try std.testing.expect(gen2 > gen1);
}

test "kitty graphics images: 여러 이미지 노출 + delete/RIS 반영, generation은 RIS에도 단조 (K2a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{2} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s}));
    try std.testing.expectEqual(@as(usize, 2), core.renderSnapshot().images.len);

    // 가장 큰 generation 기록(RIS가 카운터를 리셋하지 않는지 확인용).
    var max_gen: u64 = 0;
    for (core.renderSnapshot().images) |v| max_gen = @max(max_gen, v.generation);

    // delete(d=I, i=1) → 이미지 1만 free, 하나(2) 남는다.
    try core.write("\x1b_Ga=d,d=I,i=1\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), core.renderSnapshot().images.len);
    // RIS → 전부 비운다.
    try core.write("\x1bc");
    try std.testing.expectEqual(@as(usize, 0), core.renderSnapshot().images.len);

    // RIS 후 재transmit은 이전 max보다 큰 generation을 받는다(카운터 비리셋 — stale 재사용 방지).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try std.testing.expect(core.renderSnapshot().images[0].generation > max_gen);
}

// --- kitty graphics K3a: chunked 전송(m=1) ---

test "kitty graphics chunked(m=1): 여러 APC로 쪼갠 전송을 누적해 한 이미지로 저장 (K3a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    // 12바이트 RGB(f=24, 2x2). base64 16자(4의 배수·패딩 없음)를 8+8로 쪼갠다.
    const raw = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    var b64: [16]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    try std.testing.expectEqual(@as(usize, 16), b64s.len);
    var seq: [64]u8 = undefined;
    // 첫 청크: control + 앞 8자, m=1 → 아직 미완성이라 저장 안 됨.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=24,s=2,v=2,i=5,m=1;{s}\x1b\\", .{b64s[0..8]}));
    try std.testing.expect(!core.kitty_images.map.contains(5));
    // 마지막 청크: 뒤 8자, m=0 → 누적분을 한 번에 디코드해 저장.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Gm=0;{s}\x1b\\", .{b64s[8..16]}));
    try std.testing.expect(core.kitty_images.map.contains(5));
    const img = core.kitty_images.map.get(5).?;
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u8, 3), img.bpp);
    try std.testing.expectEqual(@as(usize, 12), img.data.len);
    try std.testing.expectEqual(@as(u8, 1), img.data[0]);
    try std.testing.expectEqual(@as(u8, 12), img.data[11]);
    try std.testing.expect(core.kitty_chunk_cmd == null); // 완료 후 chunking 비활성
}

test "kitty graphics chunked: 3청크 완성 + RIS가 진행 중 전송을 폐기 (K3a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0xAA} ** 12;
    var b64: [16]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [64]u8 = undefined;
    // 3청크(4+4+8, 각 4의 배수): m=1, m=1, m=0.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=24,s=2,v=2,i=9,m=1;{s}\x1b\\", .{b64s[0..4]}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Gm=1;{s}\x1b\\", .{b64s[4..8]}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Gm=0;{s}\x1b\\", .{b64s[8..16]}));
    try std.testing.expect(core.kitty_images.map.contains(9));
    try std.testing.expectEqual(@as(usize, 12), core.kitty_images.map.get(9).?.data.len);

    // 진행 중(m=1) 상태에서 RIS → 폐기되어 저장 안 됨.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=24,s=2,v=2,i=10,m=1;{s}\x1b\\", .{b64s[0..8]}));
    try std.testing.expect(core.kitty_chunk_cmd != null); // chunking 진행 중
    try core.write("\x1bc"); // RIS
    try std.testing.expect(!core.kitty_images.map.contains(10));
    try std.testing.expect(core.kitty_chunk_cmd == null); // 폐기됨
}

// --- kitty graphics K3b: zlib 압축(o=z) ---

test "kitty graphics zlib(o=z): 압축 픽셀 inflate 저장 + 크기 불일치/깨진 zlib 거부 (K3b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    // 2x2 RGB(12바이트 [1..12])를 zlib 압축한 base64(python zlib.compress).
    try core.write("\x1b_Ga=t,f=24,s=2,v=2,i=5,o=z;eJxjZGJmYWVj5+Dk4uYBAAF4AE8=\x1b\\");
    try std.testing.expect(core.kitty_images.map.contains(5));
    const img = core.kitty_images.map.get(5).?;
    try std.testing.expectEqual(@as(usize, 12), img.data.len);
    try std.testing.expectEqual(@as(u8, 3), img.bpp);
    try std.testing.expectEqual(@as(u8, 1), img.data[0]);
    try std.testing.expectEqual(@as(u8, 12), img.data[11]); // inflate 정확

    // 같은 압축인데 선언 치수가 틀리면(s=3,v=3 → expected 36 ≠ inflate 12) 거부.
    try core.write("\x1b_Ga=t,f=24,s=3,v=3,i=6,o=z;eJxjZGJmYWVj5+Dk4uYBAAF4AE8=\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(6));
    // 깨진 zlib(헤더 0x78 아님)도 graceful 거부(panic 없음).
    try core.write("\x1b_Ga=t,f=24,s=2,v=2,i=7,o=z;AAAAAAAA\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(7));
}

test "kitty graphics zlib: 큰 이미지(back-reference 포함) inflate (K3b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer core.deinit();
    // 8x8 RGBA(256바이트) zlib 압축 — LZ77 back-reference가 든 스트림(작은 것만으론 검증 부족).
    try core.write("\x1b_Ga=t,f=32,s=8,v=8,i=8,o=z;eJwBAAH//gAHDhUcIyoxOD9GTVRbYmlwd36FjJOaoaivtr3Ey9LZ4Ofu9fwDChEYHyYtNDtCSVBXXmVsc3qBiI+WnaSrsrnAx87V3OPq8fj/Bg0UGyIpMDc+RUxTWmFob3Z9hIuSmaCnrrW8w8rR2N/m7fT7AgkQFx4lLDM6QUhPVl1ka3J5gIeOlZyjqrG4v8bN1Nvi6fD3/gUMExohKC82PURLUllgZ251fIOKkZifpq20u8LJ0Nfe5ezz+gEIDxYdJCsyOUBHTlVcY2pxeH+GjZSboqmwt77FzNPa4ejv9v0ECxIZICcuNTxDSlFYX2ZtdHuCiZCXnqWss7rByM/W3eTr8vkKE3+B\x1b\\");
    try std.testing.expect(core.kitty_images.map.contains(8));
    const img = core.kitty_images.map.get(8).?;
    try std.testing.expectEqual(@as(usize, 256), img.data.len);
    try std.testing.expectEqual(@as(u8, 0), img.data[0]);
    try std.testing.expectEqual(@as(u8, 249), img.data[255]); // 마지막 바이트까지 정확
}

// --- kitty graphics K3c: PNG 디코드(f=100, 8-bit truecolor) ---

test "kitty graphics PNG(f=100): RGBA/RGB 디코드 저장(s/v 없이) (K3c)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    // 2x2 RGBA PNG(PIL 생성). f=100, s/v 없음 — PNG가 치수를 자기기술.
    try core.write("\x1b_Ga=t,f=100,i=1;iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAF0lEQVR4nGP4z8Dwn+E/QwMTI5hmOAAAOrcGP3V8arYAAAAASUVORK5CYII=\x1b\\");
    try std.testing.expect(core.kitty_images.map.contains(1));
    const a = core.kitty_images.map.get(1).?;
    try std.testing.expectEqual(@as(u32, 2), a.width);
    try std.testing.expectEqual(@as(u32, 2), a.height);
    try std.testing.expectEqual(@as(u8, 4), a.bpp);
    try std.testing.expectEqual(@as(usize, 16), a.data.len);
    try std.testing.expectEqual(@as(u8, 255), a.data[0]); // 첫 픽셀 R
    try std.testing.expectEqual(@as(u8, 64), a.data[15]); // 마지막 픽셀 A

    // 3x2 RGB PNG(color type 2).
    try core.write("\x1b_Ga=t,f=100,i=2;iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAE0lEQVR4nGPkEpGDAJaoqCgICwAY2AK4OdDUoAAAAABJRU5ErkJggg==\x1b\\");
    const b = core.kitty_images.map.get(2).?;
    try std.testing.expectEqual(@as(u32, 3), b.width);
    try std.testing.expectEqual(@as(u8, 3), b.bpp);
    try std.testing.expectEqual(@as(usize, 18), b.data.len);
    try std.testing.expectEqual(@as(u8, 10), b.data[0]);
    try std.testing.expectEqual(@as(u8, 180), b.data[17]);
}

test "kitty graphics PNG: 필터 다양한 그라데이션 디코드 + 미지원/깨진 PNG graceful 거부 (K3c)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer core.deinit();
    // 16x16 RGBA 그라데이션 — PIL 적응 필터(Sub/Up/Average/Paeth)를 거쳐 unfilter 전 경로를 실증.
    try core.write("\x1b_Ga=t,f=100,i=3;iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAXUlEQVR4nKXMRw6AMBAEwTEMOf7/syD5ALKcdteH6mM7AM8NwIq+cGb8B50Jw0GvxnhAFaYHgxjzg1GE5cFUxfpgLqJssGRRPliTqBtsEeoHe8A4OD4Ng9NrHFx4ARfXB/WGjsh8AAAAAElFTkSuQmCC\x1b\\");
    try std.testing.expect(core.kitty_images.map.contains(3));
    const g = core.kitty_images.map.get(3).?;
    try std.testing.expectEqual(@as(u32, 16), g.width);
    try std.testing.expectEqual(@as(u32, 16), g.height);
    try std.testing.expectEqual(@as(usize, 1024), g.data.len);
    try std.testing.expectEqual(@as(u8, 0), g.data[0]);
    try std.testing.expectEqual(@as(u8, 255), g.data[1023]); // 마지막 바이트까지 정확

    // grayscale(color type 0)은 미지원 변종 → graceful 거부(저장 안 됨, panic 없음).
    try core.write("\x1b_Ga=t,f=100,i=4;iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAAAAABX3VL4AAAADklEQVR4nGNgcGBo+A8AAwUBwE4zW+kAAAAASUVORK5CYII=\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(4));
    // 깨진 PNG(서명 틀림)도 graceful 거부.
    try core.write("\x1b_Ga=t,f=100,i=5;AAAAAAAAAAAA\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(5));
}

// --- kitty graphics K4a: 세분화된 delete(a=d, d= 타깃) ---

test "kitty graphics delete: d=a(전체 placement만)·d=A(이미지까지) (K4a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=1\x1b\\");
    try core.write("\x1b_Ga=p,i=2\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), core.kitty_placements.items.len);

    // d 기본값 'a'(소문자) — placement만 전부 제거, 이미지는 남는다.
    try core.write("\x1b_Ga=d\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
    try std.testing.expectEqual(@as(usize, 2), core.kitty_images.map.count()); // 이미지 유지

    // d=A(대문자) — placement + 이미지 데이터까지 전부 free.
    try core.write("\x1b_Ga=p,i=1\x1b\\");
    try core.write("\x1b_Ga=d,d=A\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
    try std.testing.expectEqual(@as(usize, 0), core.kitty_images.map.count());
}

test "kitty graphics delete: d=i(placement만)·d=I(이미지까지)·placement_id 지정 (K4a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=7,p=1\x1b\\");
    try core.write("\x1b_Ga=p,i=7,p=2\x1b\\");

    // d=i,p=1 — 그 placement만 제거(이미지·다른 placement 유지).
    try core.write("\x1b_Ga=d,d=i,i=7,p=1\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    try std.testing.expect(core.kitty_images.map.contains(7));
    try std.testing.expectEqual(@as(u32, 2), core.kitty_placements.items[0].placement_id);

    // d=i(소문자, p 없음) — image 7의 남은 placement 제거, 이미지는 유지.
    try core.write("\x1b_Ga=d,d=i,i=7\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
    try std.testing.expect(core.kitty_images.map.contains(7));

    // d=I(대문자) — 이미지 데이터까지 free.
    try core.write("\x1b_Ga=d,d=I,i=7\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(7));
}

test "kitty graphics delete: d=z(z-index)·d=Z(이미지까지) (K4a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=1,p=1,z=5\x1b\\"); // z=5
    try core.write("\x1b_Ga=p,i=2,p=1,z=-1\x1b\\"); // z=-1

    // d=z,z=5(소문자) — z=5 placement만 제거, 이미지 유지.
    try core.write("\x1b_Ga=d,d=z,z=5\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    try std.testing.expectEqual(@as(i32, -1), core.kitty_placements.items[0].z);
    try std.testing.expect(core.kitty_images.map.contains(1)); // 이미지 1 유지

    // d=Z,z=-1(대문자) — z=-1 placement + 그 이미지(2)까지 free.
    try core.write("\x1b_Ga=d,d=Z,z=-1\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
    try std.testing.expect(!core.kitty_images.map.contains(2));
}

// --- kitty graphics K4b: 한도 초과 시 LRU evict(placement 없는 것·오래된 것 우선) ---

test "kitty graphics evict: 한도 초과 시 오래된(generation 작은) 이미지부터 밀어낸다 (K4b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    core.kitty_images.limit = 32; // 16바이트 이미지 2장까지만
    const raw = [_]u8{1} ** 16; // 2x2 RGBA = 16바이트
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s})); // gen1
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s})); // gen2 (total=32)
    try std.testing.expectEqual(@as(usize, 2), core.kitty_images.map.count());
    // 세 번째 → 한도 초과, 안 쓰이는 것 중 오래된 i=1 evict.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=3;{s}\x1b\\", .{b64s})); // gen3
    try std.testing.expect(!core.kitty_images.map.contains(1)); // 오래된 것 밀려남
    try std.testing.expect(core.kitty_images.map.contains(2));
    try std.testing.expect(core.kitty_images.map.contains(3));
    try std.testing.expectEqual(@as(usize, 32), core.kitty_images.total_bytes);
}

test "kitty graphics evict: placement 있는 이미지는 보호(안 쓰이는 것 먼저) (K4b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    core.kitty_images.limit = 32;
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s})); // gen1
    try core.write("\x1b_Ga=p,i=1\x1b\\"); // i=1에 placement(=used, 오래됐지만 보호)
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s})); // gen2 unused
    // 세 번째 → evict 필요. i=1(used·오래됨) 대신 i=2(unused·최신)를 밀어낸다(unused 우선).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=3;{s}\x1b\\", .{b64s})); // gen3
    try std.testing.expect(core.kitty_images.map.contains(1)); // used라 보호
    try std.testing.expect(!core.kitty_images.map.contains(2)); // unused라 밀려남
    try std.testing.expect(core.kitty_images.map.contains(3));
}

test "kitty graphics evict: 한 장이 한도보다 크면 거부(저장 안 함) (K4b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    core.kitty_images.limit = 10; // 16바이트 이미지보다 작음
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try std.testing.expect(!core.kitty_images.map.contains(1)); // 한 장이 한도 초과 — 거부
    try std.testing.expectEqual(@as(usize, 0), core.kitty_images.total_bytes);
}

test "kitty graphics evict: 모두 화면 표시 중(used)이면 새 transmit을 거부하고 화면 이미지를 보존 (code review #9)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    core.kitty_images.limit = 32; // 16바이트 2장
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    // i=1·i=2 둘 다 transmit + display(used) — 한도 꽉.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=1\x1b\\");
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=2\x1b\\");
    // i=3 새 transmit → 한도 초과지만 i=1·i=2 모두 used라 evict 불가 → i=3 거부, 화면 이미지 보존.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=3;{s}\x1b\\", .{b64s}));
    try std.testing.expect(!core.kitty_images.map.contains(3)); // 새 이미지 거부
    try std.testing.expect(core.kitty_images.map.contains(1)); // 화면 이미지 보존
    try std.testing.expect(core.kitty_images.map.contains(2));
    try std.testing.expect(kitty.kittyImageHasPlacement(&core, 1));
    try std.testing.expect(kitty.kittyImageHasPlacement(&core, 2));
}

test "kitty graphics: 재transmit이 한도로 거부되면 그 image_id placement를 orphan으로 남기지 않는다 (code review #8)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    core.kitty_images.limit = 32;
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    // i=1(used)·i=2(used) — 한도 꽉(32).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=1\x1b\\");
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=2\x1b\\");
    try std.testing.expect(kitty.kittyImageHasPlacement(&core, 1));
    // i=1을 더 큰(32B) 이미지로 재transmit: evict 불가(i=2 used 보호) → add가 old i=1 제거 후 거부.
    const raw_big = [_]u8{2} ** 32; // 4x2 RGBA = 32
    var b64b: [44]u8 = undefined;
    const b64bs = std.base64.standard.Encoder.encode(&b64b, &raw_big);
    var seq2: [120]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq2, "\x1b_Ga=t,f=32,s=4,v=2,i=1;{s}\x1b\\", .{b64bs}));
    try std.testing.expect(!core.kitty_images.map.contains(1)); // 재transmit 거부(old i=1 제거됨)
    try std.testing.expect(!kitty.kittyImageHasPlacement(&core, 1)); // placement도 정리 — orphan 없음
    try std.testing.expect(core.kitty_images.map.contains(2)); // i=2 보존
    try std.testing.expect(kitty.kittyImageHasPlacement(&core, 2));
}

test "kitty graphics: chunked 전송 중 독립 명령(delete)이 오면 chunk를 버리고 새 명령을 실행 (code review #3)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    // i=1 저장(delete 대상).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try std.testing.expect(core.kitty_images.map.contains(1));
    // i=2 chunked transmit 시작(m=1) — 진행 중.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2,m=1;{s}\x1b\\", .{b64s}));
    try std.testing.expect(core.kitty_chunk_cmd != null); // chunk 진행 중
    // 진행 중에 독립 명령 a=d(delete) 도착 → chunk를 버리고 delete를 즉시 실행한다(transmit이 아니라서).
    try core.write("\x1b_Ga=d,d=I,i=1\x1b\\");
    try std.testing.expect(core.kitty_chunk_cmd == null); // 진행 중 chunk 폐기
    try std.testing.expect(!core.kitty_images.map.contains(1)); // delete가 실제로 실행됨
    try std.testing.expect(!core.kitty_images.map.contains(2)); // 버려진 chunked i=2는 저장 안 됨
}

test "kitty graphics: 단일 APC가 4096B를 넘는 큰 transmit도 받는다 (동적 버퍼, code review #4)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    // 40x40 RGBA = 6400B 픽셀 → base64 ~8534자, APC body가 옛 고정 4096 버퍼를 훌쩍 넘는다.
    const px: usize = 40 * 40 * 4;
    const raw = try std.testing.allocator.alloc(u8, px);
    defer std.testing.allocator.free(raw);
    @memset(raw, 7);
    const b64 = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(px));
    defer std.testing.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, raw);
    const seq = try std.fmt.allocPrint(std.testing.allocator, "\x1b_Ga=t,f=32,s=40,v=40,i=1;{s}\x1b\\", .{b64});
    defer std.testing.allocator.free(seq);
    try core.write(seq);
    // 과거엔 4096 초과 → apc_overflow로 silent drop. 이제 동적 버퍼라 정상 저장된다.
    try std.testing.expect(core.kitty_images.map.contains(1));
    try std.testing.expectEqual(@as(u32, 40), core.kitty_images.map.get(1).?.width);
}

test "kitty graphics: 자동 크기 이미지가 셀 메트릭으로 커서를 advance한다 (code review #2)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer core.deinit();
    core.setCellMetrics(8, 16); // 셀 8×16 px (platform 주입 모사)
    // 16×48 px RGBA 이미지: 높이 48 / 셀 16 = 정확히 3행. c/r 미지정(자동 크기)이라 코어가 메트릭으로 환산.
    const px: usize = 16 * 48 * 4;
    const raw = try std.testing.allocator.alloc(u8, px);
    defer std.testing.allocator.free(raw);
    @memset(raw, 9);
    const b64 = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(px));
    defer std.testing.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, raw);
    const seq = try std.fmt.allocPrint(std.testing.allocator, "\x1b_Ga=T,f=32,s=16,v=48,i=1;{s}\x1b\\", .{b64});
    defer std.testing.allocator.free(seq);
    try core.write(seq); // a=T: transmit + display(커서 위치에 placement + advance)
    try std.testing.expectEqual(@as(u16, 3), core.screen.cursor.row); // 48px / 16px = 3행 내려감
}

test "kitty graphics: 셀 메트릭이 없으면 자동 크기는 커서를 안 옮긴다 (K1 fallback)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer core.deinit();
    // setCellMetrics 호출 안 함 → cell_height_px==0 (헤드리스). 자동 크기는 환산 불가라 미advance.
    const px: usize = 16 * 48 * 4;
    const raw = try std.testing.allocator.alloc(u8, px);
    defer std.testing.allocator.free(raw);
    @memset(raw, 9);
    const b64 = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(px));
    defer std.testing.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, raw);
    const seq = try std.fmt.allocPrint(std.testing.allocator, "\x1b_Ga=T,f=32,s=16,v=48,i=1;{s}\x1b\\", .{b64});
    defer std.testing.allocator.free(seq);
    try core.write(seq);
    try std.testing.expectEqual(@as(u16, 0), core.screen.cursor.row); // 메트릭 없음 → 미이동(K1대로)
}

test "mode 2027: skin tone after a flag does not clobber the flag's combining (review #15)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?2027h");
    // 국기 🇰🇷 한 셀(combining = 2번째 RI). 이어서 스킨톤 modifier 🏽.
    try core.write("\xf0\x9f\x87\xb0\xf0\x9f\x87\xb7\xf0\x9f\x8f\xbd");
    // 국기의 combining은 2번째 RI 그대로 — 스킨톤이 덮어쓰지 않는다.
    try std.testing.expectEqual(@as(u21, 0x1F1F0), core.screen.cells[0].codepoint);
    try expectCluster(&core, core.screen.cells[0].grapheme_id, &.{0x1F1F7}); // 안 깨짐
    // 스킨톤은 국기에 못 붙으니 별도 셀(putCell, EAW Wide).
    try std.testing.expectEqual(@as(u21, 0x1F3FD), core.screen.cells[2].codepoint);
}

test "mode 2027: emoji promotion at the last column wraps to next line as width 2 (review #9)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?2027h");
    try core.write("abcd"); // cols 0-3, 커서 col4(마지막)
    try core.write("\xe2\x9d\xa4\xef\xb8\x8f"); // ❤(col4, width1) + VS16 -> 마지막 칸 승격 불가 -> wrap
    // 이전 줄 마지막 칸은 비워지고, ❤️가 다음 줄에 width 2로.
    try std.testing.expect(types.isUnwritten(core.screen.cells[4])); // row0 col4 비움
    try std.testing.expect(core.screen.wrapped[0]); // soft-wrap 표시
    try std.testing.expectEqual(@as(u21, 0x2764), core.screen.cells[5].codepoint); // row1 col0
    try expectCluster(&core, core.screen.cells[5].grapheme_id, &.{0xFE0F});
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[5].width);
    try std.testing.expect(core.screen.cells[6].continuation);
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);
}

test "RIS restores alternate_scroll to factory default (review #14)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?1007l"); // 프로그램이 alternate_scroll 끔
    try std.testing.expect(!core.alternate_scroll);
    try core.write("\x1bc"); // RIS
    try std.testing.expect(core.alternate_scroll); // 공장 기본(켜짐) 복원
}

// === 응답 적합성(conformance) — 호스트로 돌려보내는 report를 명세 기대값과 직접 비교한다.
// esctest(GPL)를 안 쓰는 대신 공개 명세에서 자체 도출한다. docs/conformance-testing.md 참조.

test "conformance: DA2 (CSI > c) answers secondary device attributes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // xterm ctlseqs Secondary DA. VT220급(1), 버전 10, ROM 0.
    try core.write("\x1b[>c");
    try std.testing.expectEqualStrings("\x1b[>1;10;0c", core.pendingResponse());
}

// XTVERSION(CSI > q, Ps=0): xterm ctlseqs "Report xterm name and version". 응답은 DCS 시퀀스
// `DCS > | <name version> ST`(= ESC P > | ... ESC \). 이건 런타임 자기식별의 백본이다 — DA1/DA2가
// 범용 VT102/VT220 신원만 주는 것과 달리, XTVERSION은 "이 단말은 maru다"를 이름으로 알린다. terminfo
// 파일이 원격에 없어도 capability를 런타임 질의로 감지하는 도구(tmux/nvim 등)가 maru를 식별할 수 있게
// 하는 가장 미래지향적 채널이며, terminfo·XTGETTCAP 작업이 공유할 단일 신원 출처(terminal_name/version)다.
test "conformance: XTVERSION (CSI > q) reports terminal name and version over DCS, no SGR leak" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[>q");
    // 정확한 wire 바이트를 고정한다("추측 말고 캡처"): ESC P > | maru 0.0.0 ESC \.
    try std.testing.expectEqualStrings("\x1bP>|maru 0.0.0\x1b\\", core.pendingResponse());
    core.clearResponse();
    // '>' 마커 시퀀스가 뒤따르는 SGR로 새지 않는다(DA2 격리 테스트와 같은 불변식).
    try core.write("\x1b[4m"); // underline on
    try core.write("X");
    try std.testing.expect(core.screen.cells[0].style.underline);
}

test "XTVERSION (CSI > q) ignores non-zero Ps (only Ps=0 is defined)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // xterm ctlseqs는 Ps=0만 XTVERSION으로 정의한다. 그 외 Ps는 미정의라 침묵한다(안전 기본값).
    try core.write("\x1b[>1q");
    try std.testing.expectEqualStrings("", core.pendingResponse());
}

// XTGETTCAP(`DCS + q <hex names> ST`): terminfo/termcap 캡 런타임 질의(xterm ctlseqs). terminfo 파일이
// 원격에 없어도 도구가 캡을 직접 물어 자기식별/기능 협상을 한다 — XTVERSION과 함께 "파일 없는 자기식별"
// 두 번째 채널. maru가 정직하게 아는 캡만 응답하고(TN=단말 이름·Co=색 수·RGB=truecolor) 나머지는 0+r.
test "conformance: XTGETTCAP (DCS + q) answers TN/Co/RGB, 0+r for unknown" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // RGB = hex 524742, 값 "8" = hex 38. 응답 이름은 요청 hex를 그대로 echo, 값은 대문자 hex.
    try core.write("\x1bP+q524742\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1+r524742=38\x1b\\", core.pendingResponse());
    core.clearResponse();
    // Co = 436f, 값 "256" = 323536.
    try core.write("\x1bP+q436f\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1+r436f=323536\x1b\\", core.pendingResponse());
    core.clearResponse();
    // TN = 544e, 값 "xterm-maru"(terminfo 이름) = 787465726D2D6D617275.
    try core.write("\x1bP+q544e\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1+r544e=787465726D2D6D617275\x1b\\", core.pendingResponse());
    core.clearResponse();
    // 모르는 캡(ZZ = 5a5a) → 0+r(요청 hex echo).
    try core.write("\x1bP+q5a5a\x1b\\");
    try std.testing.expectEqualStrings("\x1bP0+r5a5a\x1b\\", core.pendingResponse());
}

test "XTGETTCAP: 여러 캡은 ;로 구분 — 각각 per-cap 응답(알려짐 1+r, 모름 0+r)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // RGB(알려짐) ; ZZ(모름): 1+r 다음 0+r를 차례로.
    try core.write("\x1bP+q524742;5a5a\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1+r524742=38\x1b\\\x1bP0+r5a5a\x1b\\", core.pendingResponse());
}

test "conformance: DECRQM reports known modes (bracketed paste 2004, DECTCEM 25)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // DEC STD 070 DECRQM/DECRPM: CSI ? Ps $ p -> CSI ? Ps ; Pm $ y. Pm 1=set, 2=reset.
    // bracketed paste(2004) 기본 reset.
    try core.write("\x1b[?2004$p");
    try std.testing.expectEqualStrings("\x1b[?2004;2$y", core.pendingResponse());
    core.clearResponse();
    // 켠 뒤 set.
    try core.write("\x1b[?2004h\x1b[?2004$p");
    try std.testing.expectEqualStrings("\x1b[?2004;1$y", core.pendingResponse());
    core.clearResponse();
    // DECTCEM(25) 기본 set(커서 표시).
    try core.write("\x1b[?25$p");
    try std.testing.expectEqualStrings("\x1b[?25;1$y", core.pendingResponse());
}

test "conformance: CPR reflects cursor position after CUP and reverts after a move" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();
    // ECMA-48 8.3.20 CUP(CSI row;col H) 1-indexed로 커서 이동, 8.3.14 CPR로 보고.
    try core.write("\x1b[3;7H\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[3;7R", core.pendingResponse());
    core.clearResponse();
    // CUF(CSI C) 2칸 -> col 9. 응답이 새 위치를 반영.
    try core.write("\x1b[2C\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[3;9R", core.pendingResponse());
}

test "mode 2027: emoji wrap at the last column on the scroll-bottom keeps the soft-wrap flag (re-check)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b[?2027h");
    // 커서를 마지막 행(scroll_bottom=2)으로 내리고 그 행 마지막 칸까지 채운다.
    try core.write("\r\n\r\nabcd"); // row2에 abcd, 커서 col4(마지막)
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row);
    try core.write("\xe2\x9d\xa4\xef\xb8\x8f"); // ❤+VS16 -> 마지막 칸 승격 불가 -> wrap + scroll
    // scroll로 한 줄 올라가고, '이전 줄'(이제 row1)이 이모지 줄(row2)로 soft-wrap돼야 한다 —
    // scrollRangeUp 경계 fixup이 지우지 않게 lineFeed 후에 세운다.
    try std.testing.expect(core.screen.wrapped[1]); // 이전 줄 soft-wrap 유지(핵심)
    try std.testing.expectEqual(@as(u21, 0x2764), core.screen.cells[core.index(2, 0)].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.screen.cells[core.index(2, 0)].width);
    try std.testing.expect(core.screen.cells[core.index(2, 1)].continuation);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.screen.cursor.col);
}

test "backspace + overwrite renders word deletion (zsh meta-DEL response)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();
    try core.write("foo bar baz");
    // zsh가 meta-DEL(\e\x7f)에 보내는 응답: 왼쪽3 + 공백3 + 왼쪽3 = "baz" 삭제.
    try core.write("\x08\x08\x08   \x08\x08\x08");
    const line = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "foo bar    ")); // baz가 공백으로
    try std.testing.expectEqual(@as(u16, 8), core.screen.cursor.col); // "foo bar " 다음(baz 시작)
}

// ── OSC 133 semantic prompt ────────────────────────────────────────────────────────────────────

test "OSC 133: A/B/C tag the cursor row and update state (ST + BEL terminators)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // ST 종료
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.semantic_state);
    try core.write("\x1b]133;B\x07"); // BEL 종료 — 같은 행을 최신 마커로 덮어쓴다
    try std.testing.expectEqual(types.SemanticPrompt.input, core.screen.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.input, core.semantic_state);
    try core.write("\x1b]133;C\x1b\\");
    try std.testing.expectEqual(types.SemanticPrompt.command, core.screen.prompt_marks[0].kind);
}

test "cursorIsAtPrompt: 셸 통합 없음(unknown, primary 화면)은 프롬프트 아님(보수적 확인)" {
    // OSC 133을 한 번도 못 봄 → semantic_state=unknown, alt 아님. Ghostty와 동일하게 "모르면 프롬프트 아님"
    // 으로 보수적 판정한다(닫기 확인이 뜸 = 데이터 손실 방지 우선). 통합 없는 셸의 기본 상태.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try std.testing.expect(!core.cursorIsAtPrompt());
}

test "cursorIsAtPrompt: OSC 133 A/B=프롬프트, C/D=실행 중" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]133;A\x07"); // 프롬프트 시작
    try std.testing.expect(core.cursorIsAtPrompt());
    try core.write("\x1b]133;B\x07"); // 입력 대기 = 정착한 idle 프롬프트(통합 셸이 닫힐 때의 상태)
    try std.testing.expect(core.cursorIsAtPrompt());
    try core.write("\x1b]133;C\x07"); // 명령 출력 시작 = 실행 중
    try std.testing.expect(!core.cursorIsAtPrompt());
    try core.write("\x1b]133;D;0\x07"); // 명령 끝 → unknown(다음 A까지) = 프롬프트 아님
    try std.testing.expect(!core.cursorIsAtPrompt());
}

test "cursorIsAtPrompt: alt 화면(풀스크린 TUI)은 semantic 상태와 무관하게 프롬프트 아님" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]133;B\x07"); // 입력 프롬프트 상태
    try std.testing.expect(core.cursorIsAtPrompt());
    try core.write("\x1b[?1049h"); // alt 화면 진입(vim 등) — 통합이 input이라 해도 실행 중으로 본다
    try std.testing.expect(!core.cursorIsAtPrompt());
    // 코어는 alt 진입/이탈에 semantic_state를 unknown으로 되돌린다(alt는 프롬프트 의미가 없음). 그래서 TUI를
    // 빠져나온 직후, 셸이 새 프롬프트를 재마킹하기 전까진 프롬프트 아님(보수적) — precmd가 A/B를 다시 쏘면 복귀.
    try core.write("\x1b[?1049l");
    try std.testing.expect(!core.cursorIsAtPrompt());
    try core.write("\x1b]133;B\x07"); // 셸이 프롬프트 재마킹 → 프롬프트 복귀
    try std.testing.expect(core.cursorIsAtPrompt());
}

test "OSC 133: regions tag distinct rows via line-feed propagation" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // row0 = prompt
    try core.write("\r\n"); // row1 ← prompt 전파
    try core.write("\x1b]133;B\x1b\\"); // row1 = input
    try core.write("\r\n"); // row2 ← input 전파
    try core.write("\x1b]133;C\x1b\\"); // row2 = command
    try core.write("\r\nout"); // row3 ← command 전파
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.input, core.screen.prompt_marks[1].kind);
    try std.testing.expectEqual(types.SemanticPrompt.command, core.screen.prompt_marks[2].kind);
    try std.testing.expectEqual(types.SemanticPrompt.command, core.screen.prompt_marks[3].kind);
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.screen.prompt_marks[4].kind); // 영역 밖
}

test "OSC 133: a multi-row prompt propagates prompt to every line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // row0 = prompt
    try core.write("\n\n"); // LF×2 → row1·row2 ← prompt 전파
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[1].kind);
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[2].kind);
    try core.write("\x1b]133;B\x1b\\"); // 현재 행(row2)만 input으로
    try std.testing.expectEqual(types.SemanticPrompt.input, core.screen.prompt_marks[2].kind);
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[1].kind); // 앞 행은 유지
}

test "stickyCommand: 스크롤 시 뷰포트 위 명령줄(.input)+종료코드를 찾고, 바닥/맨위에선 null" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    // 한 명령 사이클: A(프롬프트)·B(입력)로 row0을 명령줄로 만들고 "> build"를 친 뒤, C(출력)·출력줄·D;0.
    try core.write("\x1b]133;A\x1b\\"); // row0 prompt
    try core.write("\x1b]133;B\x1b\\"); // row0 input(명령줄)
    try core.write("> build"); // 명령줄 텍스트(row0)
    try core.write("\r\n"); // → row1(input 전파)
    try core.write("\x1b]133;C\x1b\\"); // row1 command(출력 시작)
    try core.write("out1\r\nout2"); // row1·row2 — 아직 스크롤 안 함(3행)
    try core.write("\x1b]133;D;0\x1b\\"); // 종료코드 0 — 화면에 있는 row0(프롬프트 시작)에 스탬프
    try std.testing.expect(core.stickyCommand() == null); // 라이브 바닥(vo=0) — sticky 없음
    // 출력을 더 흘려 "> build"를 스크롤백으로 밀어낸다(RowPrompt input+exit=0이 함께 carry).
    try core.write("\r\nout3\r\nout4\r\nout5");
    try std.testing.expectEqual(@as(usize, 3), core.scrollbackLen()); // ["> build", "out1", "out2"]
    // vo=2 → top=1("out1", 출력) → 위로 거슬러 row0(명령줄) 찾음.
    core.scrollViewport(2);
    const sticky = core.stickyCommand() orelse return error.NoSticky;
    try std.testing.expectEqual(@as(usize, 0), sticky.row);
    try std.testing.expectEqual(@as(?i16, 0), sticky.exit);
    var it = types.RowCodepoints{ .cells = core.scrollbackRow(sticky.row) orelse return error.NoRow };
    try std.testing.expectEqual(@as(?u21, '>'), it.next()); // 명령줄 "> build"의 첫 글자
    // 끝까지 스크롤(vo=3 → top=0=명령줄 자체)이면 명령줄이 이미 최상단에 보이므로 null.
    core.scrollViewport(1); // vo=3
    try std.testing.expect(core.stickyCommand() == null);
}

test "OSC 133: autowrap continuation keeps the tag (glyph writes do NOT reset it)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\");
    try core.write("abcdef"); // abcd|ef soft-wrap: row0 채움 → 자동 wrap → row1
    try std.testing.expect(core.screen.wrapped[0]); // soft-wrap 표시
    // 핵심: 글자 쓰기가 태그를 리셋하지 않는다(wrapped와 다른 점). 두 행 모두 prompt.
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[1].kind);
}

test "OSC 133: D decodes the exit code; bare/invalid leaves it unchanged" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;D;0\x07");
    try std.testing.expectEqual(@as(?i32, 0), core.last_command_exit);
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.semantic_state); // 영역 닫힘
    try core.write("\x1b]133;D;12;aid=foo\x07"); // 첫 토큰만 코드, 나머지 옵션 무시
    try std.testing.expectEqual(@as(?i32, 12), core.last_command_exit);
    try core.write("\x1b]133;D;-1\x07"); // 음수 허용
    try std.testing.expectEqual(@as(?i32, -1), core.last_command_exit);
    try core.write("\x1b]133;D\x07"); // 코드 없음 → 이전 값 유지
    try std.testing.expectEqual(@as(?i32, -1), core.last_command_exit);
    try core.write("\x1b]133;D;abc\x07"); // 정수 아님 → 유지
    try std.testing.expectEqual(@as(?i32, -1), core.last_command_exit);
}

test "OSC 133: D resets state so the next row is not tagged" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]133;C\x1b\\"); // state=command
    try core.write("\x1b]133;D;0\x07"); // state=unknown
    try core.write("\r\nx"); // 다음 행은 전파되지 않아야 한다
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.screen.prompt_marks[1].kind);
}

test "OSC 133: a tagged row scrolled off carries its tag into scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // row0 = prompt
    try core.write("X"); // 글자(태그 유지)
    try core.write("\x1b]133;D;0\x07"); // state=unknown (이후 행은 태깅 안 됨)
    try core.write("\r\n\r\n"); // 두 번째 LF가 바닥에서 scroll → row0(prompt)이 스크롤백으로
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.scrollbackRowPrompt(0).kind);
}

test "OSC 133: RIS clears all tags, exit code, and state" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\X\x1b]133;D;5\x07");
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[0].kind);
    try std.testing.expectEqual(@as(?i32, 5), core.last_command_exit);
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.screen.prompt_marks[0].kind);
    try std.testing.expectEqual(@as(?i32, null), core.last_command_exit);
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.semantic_state);
}

test "OSC 133: erase-in-display mode 2 clears tags" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\");
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[0].kind);
    try core.write("\x1b[2J");
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.screen.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.semantic_state);
}

test "OSC 133: alt screen is isolated; primary tags survive the round trip" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // primary row0 = prompt
    try core.write("\x1b[?1049h"); // alt 진입
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.screen.prompt_marks[0].kind); // alt는 비분류
    try core.write("\x1b]133;C\x1b\\"); // alt row0 = command
    try std.testing.expectEqual(types.SemanticPrompt.command, core.screen.prompt_marks[0].kind);
    try core.write("\x1b[?1049l"); // primary 복귀
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[0].kind); // primary 분류 복원
}

test "OSC 133: liberal option parsing ignores unknown keys" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A;aid=14;cl=line;k=i\x07"); // 모르는 옵션 무시, 여전히 prompt
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[0].kind);
    try core.write("\x1b]133;B;barekey\x07"); // 정수 아닌 옵션도 무해
    try std.testing.expectEqual(types.SemanticPrompt.input, core.screen.prompt_marks[0].kind);
}

test "OSC 133: malformed or unknown action is ignored" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;Pextra\x07"); // action 뒤 ';' 없는 잉여 내용 → invalid
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.screen.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.semantic_state);
    try core.write("\x1b]133;Z\x07"); // 모르는 action → no-op
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.screen.prompt_marks[0].kind);
}

test "OSC 133: an overflowing sequence is ignored, later OSC still works" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    var big: [2100]u8 = undefined;
    @memset(&big, 'x');
    try core.write("\x1b]133;A;"); // OSC 시작
    try core.write(&big); // 비-클립보드 OSC 상한(max_osc_small_bytes=2048) 초과 → osc_overflow
    try core.write("\x07"); // 종료 — overflow라 dispatch가 무시
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.screen.prompt_marks[0].kind); // 태깅 안 됨
    try core.write("\x1b]133;A\x07"); // 다음 OSC는 정상 동작(overflow 리셋)
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[0].kind);
}

test "OSC 133: snapshot exposes prompt_marks and last_command_exit (non-scrolled)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\X\x1b]133;D;3\x07");
    const snap = core.snapshot();
    try std.testing.expectEqual(types.SemanticPrompt.prompt, snap.prompt_marks[0].kind);
    try std.testing.expectEqual(@as(?i32, 3), snap.last_command_exit);
}

test "OSC 133: isPromptStart marks the first row of each prompt block" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 5 });
    defer core.deinit();
    // 2 사이클: A 프롬프트 + B 입력 + \r\n + C 출력 + \r\n + D. row0·row2가 프롬프트 블록 시작.
    try core.write("\x1b]133;A\x1b\\P$ \x1b]133;B\x1b\\c1\r\n\x1b]133;C\x1b\\o1\r\n\x1b]133;D;0\x07");
    try core.write("\x1b]133;A\x1b\\P$ \x1b]133;B\x1b\\c2\r\n\x1b]133;C\x1b\\o2\r\n\x1b]133;D;1\x07");
    try std.testing.expect(core.isPromptStart(0)); // 프롬프트+입력 줄(블록 시작)
    try std.testing.expect(!core.isPromptStart(1)); // 출력
    try std.testing.expect(core.isPromptStart(2)); // 다음 블록 시작(직전이 .command)
    try std.testing.expect(!core.isPromptStart(3)); // 출력
}

test "OSC 133: jumpToPrompt scrolls the viewport to a scrollback prompt" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\aaa\r\n"); // row0=.prompt "aaa", \r\n → row1 .prompt
    try core.write("\x1b]133;C\x1b\\bbb\r\n"); // row1=.command, \r\n scroll → row0(.prompt)이 스크롤백으로
    try core.write("\x1b]133;D;0\x07");
    try std.testing.expect(core.scrollbackLen() >= 1);
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());
    try std.testing.expect(core.jumpToPrompt(-1)); // 이전 프롬프트 = 스크롤백의 .prompt
    try std.testing.expect(core.viewOffset() > 0); // 위로 스크롤됨
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.viewportRowPrompt(0).kind); // 그 프롬프트가 뷰 맨 위
}

test "OSC 133: jumpToPrompt returns false with no shell-integration classification" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("plain text\r\nno markers"); // OSC 133 없음 → 점프 타깃 없음
    try std.testing.expect(!core.jumpToPrompt(-1));
    try std.testing.expect(!core.jumpToPrompt(1));
}

test "OSC 133: reflow carries the tag of a re-wrapped (non-cursor) line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b]133;C\x1b\\"); // row0 = command(출력 영역)
    try core.write("abcdef"); // abcd|ef soft-wrap: row0(wrapped)·row1 = command
    try std.testing.expect(core.screen.wrapped[0]);
    try core.write("\r\nx"); // row2(.command 전파)로 커서 이동 → 위 wrap 줄은 커서 줄이 아니다
    try core.resize(8, 4); // 넓힘 → "abcdef"가 한 줄로 합쳐진다(재-wrap)
    try std.testing.expectEqual(@as(u21, 'a'), core.screen.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), core.screen.cells[core.index(0, 5)].codepoint);
    try std.testing.expectEqual(types.SemanticPrompt.command, core.screen.prompt_marks[0].kind); // 재-wrap 후 태그 보존
}

test "OSC 133: the verbatim cursor line keeps its tag across resize" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\p$ \x1b]133;B\x1b\\ls"); // row0: 프롬프트+입력 → .input(커서 줄)
    try std.testing.expectEqual(types.SemanticPrompt.input, core.screen.prompt_marks[0].kind);
    try core.resize(6, 4); // 좁힘 — 커서 줄은 verbatim(clip), 태그 1:1 보존
    try std.testing.expectEqual(types.SemanticPrompt.input, core.screen.prompt_marks[0].kind);
}

test "OSC 133: rows pushed to scrollback during resize carry their tag" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]133;C\x1b\\"); // command 영역
    try core.write("out1\r\nout2\r\nout3"); // row0·1·2 = command(전파), 커서 row2
    try core.write("\x1b]133;D;0\x07");
    try core.resize(8, 1); // 폭 동일, 행 3→1 → row0·row1이 스크롤백으로(태그 carry)
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try std.testing.expectEqual(types.SemanticPrompt.command, core.scrollbackRowPrompt(0).kind);
    try std.testing.expectEqual(types.SemanticPrompt.command, core.scrollbackRowPrompt(1).kind);
}

test "OSC 133: scrollback re-wrap keeps tags aligned with re-wrapped rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;C\x1b\\"); // command 영역
    try core.write("abcdefgh"); // row0 꽉 채움(.command, pending wrap)
    try core.write("ij"); // wrap → row1(.command), 커서 row1
    try std.testing.expect(core.screen.wrapped[0]);
    try core.write("\r\n\r\n"); // 두 번 scroll → 논리 줄 abcdefghij가 스크롤백으로(.command)
    try std.testing.expect(core.scrollbackLen() >= 2);
    screen.rewrapScrollback(&core, 4); // 폭 4로 재-wrap: abcd|efgh|ij — 모두 .command 유지
    var i: usize = 0;
    var saw_command = false;
    while (i < core.scrollbackLen()) : (i += 1) {
        // 재-wrap된 모든 행이 .command여야 한다(stale .unknown이면 PR1 misalignment 회귀).
        try std.testing.expectEqual(types.SemanticPrompt.command, core.scrollbackRowPrompt(i).kind);
        saw_command = true;
    }
    try std.testing.expect(saw_command);
}

test "OSC 133: a realistic zsh prompt+command sequence classifies rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    // 실제 Maru zsh 통합이 emit하는 형태(PTY 캡처로 확인): A·프롬프트·B·입력·CR/LF·C·출력·CR/LF·D;0.
    try core.write("\x1b]133;A\x1b\\"); // 프롬프트 시작 → row0=.prompt
    try core.write("myprompt$ "); // 프롬프트 텍스트(태그 유지)
    try core.write("\x1b]133;B\x1b\\"); // 입력 시작(같은 줄) → row0=.input
    try core.write("echo hi"); // 사용자 입력
    try core.write("\r\n"); // Enter → row1(.input 전파)
    try core.write("\x1b]133;C\x1b\\"); // 출력 시작 → row1=.command
    try core.write("hi\r\n"); // 명령 출력 → row2(.command 전파)
    try core.write("\x1b]133;D;0\x07"); // 명령 끝, exit 0 → state=unknown
    try std.testing.expectEqual(types.SemanticPrompt.input, core.screen.prompt_marks[0].kind); // 프롬프트+입력 줄
    try std.testing.expectEqual(types.SemanticPrompt.command, core.screen.prompt_marks[1].kind); // 출력 줄
    try std.testing.expectEqual(@as(?i32, 0), core.last_command_exit);
}

test "OSC 133: D stamps the exit code on the command's prompt-start row" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 6 });
    defer core.deinit();
    // 성공 명령: A $ B ls C out D;0 — exit 0이 프롬프트 시작 행(row0)에 스탬프된다.
    try core.write("\x1b]133;A\x1b\\$ \x1b]133;B\x1b\\ls\r\n\x1b]133;C\x1b\\out\r\n\x1b]133;D;0\x07");
    try std.testing.expectEqual(@as(?i16, 0), core.screen.prompt_marks[0].exit); // 프롬프트 시작 행
    try std.testing.expectEqual(@as(?i16, null), core.screen.prompt_marks[1].exit); // 출력 행엔 없음
    // 실패 명령: 다음 프롬프트(row2 시작)에 exit 1.
    try core.write("\x1b]133;A\x1b\\$ \x1b]133;B\x1b\\false\r\n\x1b]133;C\x1b\\\r\n\x1b]133;D;1\x07");
    try std.testing.expectEqual(@as(?i16, 1), core.screen.prompt_marks[2].exit);
    try std.testing.expectEqual(@as(?i16, 0), core.screen.prompt_marks[0].exit); // 첫 명령 exit는 그대로
}

test "OSC 133: the stamped exit carries with the row into scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // 실제 흐름: A $ B(입력 줄) \r\n C(출력 시작) \r\n(scroll) D;7. 입력 줄(row0)이 스크롤백으로
    // 밀려난 뒤 D가 그 행에 exit 7을 스탬프 → 스크롤백 행에 exit가 carry된다.
    try core.write("\x1b]133;A\x1b\\$\x1b]133;B\x1b\\\r\n\x1b]133;C\x1b\\\r\n\x1b]133;D;7\x07");
    try std.testing.expect(core.scrollbackLen() >= 1);
    try std.testing.expectEqual(@as(?i16, 7), core.scrollbackRowPrompt(0).exit); // exit carry
}

test "OSC 133: re-wrap keeps the exit on exactly one row (no duplicate gutter) [review #1]" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 6 });
    defer core.deinit();
    // 긴 입력으로 프롬프트 줄이 soft-wrap되고 exit가 leader(row0)에 스탬프된다.
    try core.write("\x1b]133;A\x1b\\$ \x1b]133;B\x1b\\");
    try core.write("0123456789012345678901234"); // 25자 → row0(20)+row1(5) .input
    try core.write("\r\n\x1b]133;C\x1b\\\r\n\x1b]133;D;0\x07");
    var before: usize = 0;
    for (0..core.size.rows) |r| {
        if (core.screen.prompt_marks[r].exit != null) before += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), before); // leader 한 행에만
    try core.resize(8, 8); // 좁힘 → 그 줄이 더 쪼개진다. exit는 여전히 한 행에만(중복 거터 방지).
    var after: usize = 0;
    for (0..core.size.rows) |r| {
        if (core.screen.prompt_marks[r].exit != null) after += 1;
    }
    for (0..core.scrollbackLen()) |i| {
        if (core.scrollbackRowPrompt(i).exit != null) after += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), after); // 재-wrap 후에도 거터 바 1개
}

test "OSC 133: scrollRangeDown (RI/IL) carries the tag down and blanks the inserted row [review #2]" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // row0 = .prompt, 커서 row0(scroll_top)
    try core.write("\x1bM"); // RI: scroll region을 아래로 → row0 내용·태그가 row1로, row0은 빈 행
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.screen.prompt_marks[0].kind); // 삽입된 빈 행 비분류
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.screen.prompt_marks[1].kind); // 태그가 내려감
}

test "OSC 133: renderSnapshot composes prompt_marks for the scrolled viewport" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // row0 = prompt
    try core.write("X\x1b]133;D;0\x07"); // 태그 고정 + state 닫기
    try core.write("\r\n\r\n"); // row0(prompt) → 스크롤백
    core.scrollViewport(1); // 한 줄 위로: 윗줄에 스크롤백(prompt)
    const snap = core.renderSnapshot();
    try std.testing.expectEqual(types.SemanticPrompt.prompt, snap.prompt_marks[0].kind);
}

// 셸 의미 이벤트 스트림은 관측 가능성의 토대다 — 같은 도메인 데이터를 디버그 로그·테스트·후속
// trace가 공유한다. 핵심 검증: OSC 133/7 한 명령 사이클이 정확한 '경계 이벤트 순서'를 낸다
// (E2E가 명령 경계를 상태 스냅샷이 아니라 이벤트로 결정적으로 단언할 수 있어야 한다).
test "shell events: a full command cycle emits prompt/input/command/end + cwd in order" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();

    // 프롬프트 시작(A) → 입력 시작(B) → 출력 시작(C) → cwd 보고(OSC 7) → 명령 끝(D;0).
    try core.write("\x1b]133;A\x1b\\"); // row 0
    try core.write("\x1b]133;B\x07ls\r\n"); // 입력 시작 후 명령 타이핑 + 개행 → row 1
    try core.write("\x1b]133;C\x07out\r\n"); // 출력 시작 → row 2
    try core.write("\x1b]7;file://h/tmp\x07"); // cwd 변경
    try core.write("\x1b]133;D;0\x07"); // 명령 끝, 종료코드 0

    const events = core.shellEvents();
    try std.testing.expect(!core.shellEventsOverflowed());
    try std.testing.expectEqual(@as(usize, 5), events.len);
    try std.testing.expectEqual(types.ShellEvent{ .prompt_start = 0 }, events[0]);
    try std.testing.expectEqual(types.ShellEvent{ .input_start = 0 }, events[1]);
    try std.testing.expectEqual(types.ShellEvent{ .command_start = 1 }, events[2]);
    try std.testing.expectEqual(types.ShellEvent{ .cwd_changed = {} }, events[3]);
    try std.testing.expectEqual(types.ShellEvent{ .command_end = .{ .row = 2, .exit = 0 } }, events[4]);
    // cwd 값 자체는 currentCwd()가 권위(이벤트는 경계만 표시).
    try std.testing.expectEqualStrings("/tmp", core.currentCwd());
}

test "shell events: command_end carries the failing exit code; clear empties the stream" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();

    try core.write("\x1b]133;D;130\x07"); // SIGINT 종료(130) — 음수가 아니어도 실패
    var events = core.shellEvents();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(types.ShellEvent{ .command_end = .{ .row = 0, .exit = 130 } }, events[0]);

    // D에 code가 없으면 exit=null(명세상 D는 code 없이도 온다).
    core.clearShellEvents();
    try std.testing.expectEqual(@as(usize, 0), core.shellEvents().len);
    try core.write("\x1b]133;D\x07");
    events = core.shellEvents();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(types.ShellEvent{ .command_end = .{ .row = 0, .exit = null } }, events[0]);
}

test "VS16 attaches to the base as a combining mark (one cell), shaper sees the emoji cluster" {
    // width.zig(중립 Unicode 폭)에서 옮겨온 core 통합 테스트 — base + VS16 결합이 한 글자, 폭은 EAW per-codepoint.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\xe2\x9d\xa4\xef\xb8\x8f"); // ❤(U+2764) + VS16(U+FE0F)
    // 폭은 EAW per-codepoint(❤=1, VS16=0) — zsh와 일치시켜 붙여넣기 redraw가 안 깨지게(폭 승격하면 CSI<N>D recolor 어긋남).
    try std.testing.expectEqual(@as(u21, 0x2764), core.screen.cells[0].codepoint);
    try expectCluster(&core, core.screen.cells[0].grapheme_id, &.{0xFE0F});
    try std.testing.expectEqual(@as(u2, 1), core.screen.cells[0].width); // EAW Neutral = 1(zsh 일치)
    try std.testing.expect(types.isUnwritten(core.screen.cells[1])); // 다음 칸은 빈칸
    try std.testing.expectEqual(@as(u16, 1), core.screen.cursor.col);
}

// 문자열 시퀀스(OSC/DCS/APC) 도중의 ESC는 그 시퀀스를 취소하고 **그 ESC부터 새 시퀀스를 시작**한다
// (ECMA-48·vt100.net DEC 상태 머신의 anywhere transition). 예전에는 abort하며 ESC를 소비해, 뒤따르는
// `]777;notify;…`가 본문 텍스트로 화면에 찍히고 알림은 유실됐다. 터미널에서 중요한 이유: TUI는 프레임마다
// 타이틀 OSC를 다시 쓰므로 알림 OSC가 그 사이에 끼어드는 인터리빙이 실제로 일어나며(실측), 증상이 셋으로
// 번진다 — 알림 유실 + 제어 문자열이 사용자 화면에 노출 + 그 줄이 화면 하단을 차지해 agent observer의
// 거리 게이트가 blocker 근거를 잘라내 승인 대기가 유휴로 뒤집힌다.
test "문자열 시퀀스 abort는 ESC를 삼키지 않고 새 시퀀스로 재시작한다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();

    const cases = [_]struct { prefix: []const u8, body: []const u8 }{
        .{ .prefix = "\x1b]0;title-being-set", .body = "osc-restart" }, // 미완성 OSC 뒤 새 OSC(실측 재현 경로)
        .{ .prefix = "\x1b", .body = "esc-esc" }, // ESC 다음에 또 ESC
        .{ .prefix = "\x1bP1$r", .body = "dcs-abort" }, // 미완성 DCS
        .{ .prefix = "\x1b_Gi=1", .body = "apc-abort" }, // 미완성 APC(kitty graphics)
        .{ .prefix = "\x1b[38;2;1", .body = "csi-abort" }, // 미완성 CSI
    };
    for (cases) |c| {
        try core.write(c.prefix);
        try core.write("\x1b]777;notify;T;");
        try core.write(c.body);
        try core.write("\x07");
        const n = core.pendingNotification() orelse return error.NotificationLost;
        try std.testing.expectEqualStrings("T", n.title);
        try std.testing.expectEqualStrings(c.body, n.body);
        core.clearNotification();
    }
}

test "abort된 시퀀스 뒤 OSC 본문이 화면 텍스트로 새지 않는다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();
    // 실측 증상: 화면에 `]777;notify;Claude Code;Claude needs your permission`이 글자로 찍혔다.
    try core.write("\x1b]0;incomplete");
    try core.write("\x1b]777;notify;Claude Code;Claude needs your permission\x07");
    try std.testing.expect(core.pendingNotification() != null);
    core.clearNotification();

    // 첫 행에 제어 문자열 조각이 남아 있으면 안 된다.
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(std.testing.allocator);
    for (core.viewportRow(0)) |cell| {
        const cp = cell.codepoint;
        if (cp == 0 or cp == ' ') continue;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
        try row.appendSlice(std.testing.allocator, buf[0..len]);
    }
    try std.testing.expect(std.mem.indexOf(u8, row.items, "777") == null);
    try std.testing.expect(std.mem.indexOf(u8, row.items, "notify") == null);
}
