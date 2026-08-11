//! TermRuntimeBackend — terminal runtime(PTY + 셸 프로세스)의 수명·입출력·관측을 GUI layout에서
//! 분리하는 vtable 계약(docs/persistent-session-host.md §13 P2).
//!
//! 왜 필요한가: 지금까지 GUI layout(`Model(TermRuntime).Term`의 `rt.live_pty`)은 `*app.LivePtySession`을
//! **직접 포인터로** 들고 spawn/attach/pump/close/foreground 관측을 그 위에서 불렀다. 이 직접 결합은
//! "GUI가 프로세스 경계를 안다"는 뜻이라, 앱 프로세스 밖(`maru-sessiond`)에 runtime을 두는 P3 이후로 갈 수
//! 없다. 이 계약은 그 결합을 **opaque `RuntimeHandle` + vtable** 하나로 바꾼다 — GUI는 handle과 이 계약만
//! 쥐고, 실제 runtime이 in-process인지 원격 host인지 모른다.
//!
//! 계약 형태(vtable): 기존 `runtime.PtyIo`(ctx + fn 포인터)와 **같은 관용구**다. `ctx`는 backend 구현
//! 인스턴스를, `vtable`은 그 구현의 함수 표를 가리킨다. P2 현재 유일한 구현은 in-process adapter
//! (`in_process_term_backend.zig` — 기존 `LiveSurfaceRegistry` + `LivePtySession` + `SurfaceRuntime`을 감쌈)이고,
//! P3의 `maru-sessiond` backend가 **같은 계약 뒤에** 들어온다(계약은 이 파일, transport는 별도 — 한 파일에
//! GUI layout 정책과 session-host transport를 섞지 않는다, docs/project-structure.md).
//!
//! 레이어: `src/app`(L4)이라 pty/session/terminal을 자유롭게 import한다(tests/boundary/imports.zig는 app에
//! forbidden 규칙을 두지 않는다). GUI layout(`session_model.Term`)은 이 계약 타입만 알고 `LivePtySession`을
//! 모른다 — 그것이 P2의 seam 목표다.
//!
//! 스레드: 모든 계약 호출은 메인 스레드 전용이다(surface_id·세션 트리·createTerm/destroyTerm 계약과 동일).
//! reader 스레드는 backend 내부에서 core에 직접 쓰고(setProcessing) 이 계약 표면을 건드리지 않는다.

const std = @import("std");
const terminal = @import("../terminal.zig");
const pty = @import("../pty.zig");
const resource_usage = @import("../session/resource_usage.zig"); // 상태바 리소스 표본의 **순수** 타입(플랫폼 타입을 seam 위로 올리지 않는다)
const surface_mod = @import("../session/surface.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const core_command = @import("../session/core_command.zig");

/// terminal runtime 하나를 가리키는 opaque 상관키. **의미를 비트에 인코딩하지 않는다.**
///
/// P2 in-process backend에서는 앱 전역 `SurfaceIdAllocator`가 발급한 `surface_id`(=`pty_id`)를 그대로 값으로
/// 쓴다 — 이미 `SurfaceRuntime`/`LiveSurfaceRegistry`가 surface_id 키드라 매핑이 1:1이다. 하지만 GUI는 이 값을
/// surface_id로 **해석하면 안 되고** backend에 되돌려 주는 불투명 handle로만 다뤄야 한다. P3에서 host가 발급하는
/// `runtime_id`(host process를 건너는 128-bit opaque)로 승격될 자리라, 지금 u64 별칭으로 그 경계를 미리 긋는다
/// (docs/persistent-session-host.md §4 `runtime_id`).
pub const RuntimeHandle = u64;

/// 화면(`RenderSnapshot`)과 별개인 runtime 관측의 가용성. host-backed client가 구 host에 붙었거나 아직 initial
/// metadata를 못 받은 상태를 "cwd 없음/foreground 없음"으로 오인하지 않도록 empty 값과 unavailable을 구분한다.
pub const ObservationAvailability = enum {
    unavailable,
    current,
    stale,
};

/// backend가 caller-owned cache로 복사할 한 시점의 화면 외 runtime 관측. 모든 slice는 호출 동안만 유효한 view이고,
/// `RuntimeObservation.replace`가 owned copy로 바꾼다. 따라서 reader가 다음 OSC 7/0/5379에서 core 버퍼를 교체하거나
/// remote event cache가 갱신돼도 AppSession이 borrowed slice를 계속 들지 않는다.
pub const RuntimeObservationView = struct {
    availability: ObservationAvailability = .unavailable,
    revision: u64 = 0,
    observer_generation: u64 = 0,
    title_generation: u32 = 0,
    size: terminal.Size = .{ .cols = 0, .rows = 0 },
    cwd: []const u8 = "",
    /// 그 cwd를 보고한 OSC 7 authority(host). 빈 문자열이면 로컬(빈 authority = VTE 규약 localhost) 또는
    /// 아직 보고 없음이다. cwd와 **함께** 실어야 소비처가 로컬/원격을 가를 수 있다(docs/ssh-integration.md §9).
    cwd_host: []const u8 = "",
    window_title: []const u8 = "",
    ssh_remote_dest: ?[]const u8 = null,
    semantic_state: terminal.SemanticPrompt = .unknown,
    alt_active: bool = false,
    app_cursor_keys: bool = false,
    app_keypad: bool = false,
    kitty_flags: u5 = 0,
    alternate_scroll: bool = true,
    mouse_tracking: bool = false,
    /// 트래킹 모드 ordinal(0=none,1=x10,2=normal,3=button,4=any). motion(1003) 판정의 단일 출처 — 위 bool은
    /// "켜짐" 여부만이라 모션을 가를 수 없다(구 host면 0으로 남아 motion 미전송 = 기존 동작).
    mouse_tracking_mode: u8 = 0,
    bracketed_paste: bool = false,
    /// host-backed BEL 누적 횟수. 소비자가 마지막에 본 값과의 차이로 벨을 울린다(0=구 host — 안 울림).
    bell_count: u64 = 0,
    /// host-backed OSC 52 요청 seq(write/read). 소비자가 마지막에 본 값과의 차이로 처리한다(0=구 host — 비활성).
    clipboard_write_seq: u64 = 0,
    clipboard_read_seq: u64 = 0,
    /// 마지막 OSC 52 read 요청의 target(Pc) — 응답 echo용. 짧아서 관측에 함께 싣는다.
    clipboard_read_target: []const u8 = "",
    foreground_available: bool = false,
    foreground_pgid: ?i32 = null,
    foreground_processes: []const pty.types.ForegroundProcessName = &.{},
    /// 1회성 agent progress. source가 비어 있으면 caller cache의 아직 미소비 progress를 보존한다.
    agent_progress: []const u8 = "",
};

/// AppSession/RemoteRuntime이 소유하는 coherent runtime 관측 cache. 문자열과 process 배열은 모두 owned라 backend/core
/// 수명과 분리된다. stable metadata와 1회성 progress를 한 구조에 두되, 빈 progress update는 미소비 값을 지우지 않는다.
pub const RuntimeObservation = struct {
    availability: ObservationAvailability = .unavailable,
    revision: u64 = 0,
    observer_generation: u64 = 0,
    title_generation: u32 = 0,
    size: terminal.Size = .{ .cols = 0, .rows = 0 },
    cwd: std.ArrayListUnmanaged(u8) = .empty,
    /// cwd를 보고한 OSC 7 authority(owned). cwd와 한 쌍으로만 갱신된다 — 짝이 어긋나면 로컬 경로에 원격
    /// host가 붙어 표시·상속·resolve가 모두 틀어진다(docs/ssh-integration.md §9.2).
    cwd_host: std.ArrayListUnmanaged(u8) = .empty,
    window_title: std.ArrayListUnmanaged(u8) = .empty,
    ssh_remote_dest: std.ArrayListUnmanaged(u8) = .empty,
    ssh_remote_dest_present: bool = false,
    semantic_state: terminal.SemanticPrompt = .unknown,
    alt_active: bool = false,
    app_cursor_keys: bool = false,
    app_keypad: bool = false,
    kitty_flags: u5 = 0,
    alternate_scroll: bool = true,
    mouse_tracking: bool = false,
    /// 트래킹 모드 ordinal(0=none,1=x10,2=normal,3=button,4=any). motion(1003) 판정의 단일 출처 — 위 bool은
    /// "켜짐" 여부만이라 모션을 가를 수 없다(구 host면 0으로 남아 motion 미전송 = 기존 동작).
    mouse_tracking_mode: u8 = 0,
    bracketed_paste: bool = false,
    /// host-backed BEL 누적 횟수. 소비자가 마지막에 본 값과의 차이로 벨을 울린다(0=구 host — 안 울림).
    bell_count: u64 = 0,
    /// host-backed OSC 52 요청 seq(write/read). 소비자가 마지막에 본 값과의 차이로 처리한다(0=구 host — 비활성).
    clipboard_write_seq: u64 = 0,
    clipboard_read_seq: u64 = 0,
    /// 마지막 read 요청 target(Pc) — 소유 버퍼(스냅샷은 view라 캐시가 복사해 든다).
    clipboard_read_target: std.ArrayListUnmanaged(u8) = .empty,
    foreground_available: bool = false,
    foreground_pgid: ?i32 = null,
    foreground_processes: std.ArrayListUnmanaged(pty.types.ForegroundProcessName) = .empty,
    agent_progress: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *RuntimeObservation, allocator: std.mem.Allocator) void {
        self.cwd.deinit(allocator);
        self.cwd_host.deinit(allocator);
        self.window_title.deinit(allocator);
        self.clipboard_read_target.deinit(allocator);
        self.ssh_remote_dest.deinit(allocator);
        self.foreground_processes.deinit(allocator);
        self.agent_progress.deinit(allocator);
        self.* = .{};
    }

    /// view 전체를 원자적으로 owned copy한 뒤 교체한다. 중간 OOM이면 기존 cache를 보존한다. source의 progress가 비면
    /// caller가 아직 소비하지 않은 progress를 다음 poll까지 유지한다(매 metadata poll이 1회성 progress를 지우지 않게).
    pub fn replace(self: *RuntimeObservation, allocator: std.mem.Allocator, snapshot: RuntimeObservationView) !void {
        var next: RuntimeObservation = .{
            .availability = snapshot.availability,
            .revision = snapshot.revision,
            .observer_generation = snapshot.observer_generation,
            .title_generation = snapshot.title_generation,
            .size = snapshot.size,
            .ssh_remote_dest_present = snapshot.ssh_remote_dest != null,
            .semantic_state = snapshot.semantic_state,
            .alt_active = snapshot.alt_active,
            .app_cursor_keys = snapshot.app_cursor_keys,
            .app_keypad = snapshot.app_keypad,
            .kitty_flags = snapshot.kitty_flags,
            .alternate_scroll = snapshot.alternate_scroll,
            .mouse_tracking = snapshot.mouse_tracking,
            .mouse_tracking_mode = snapshot.mouse_tracking_mode,
            .bell_count = snapshot.bell_count,
            .clipboard_write_seq = snapshot.clipboard_write_seq,
            .clipboard_read_seq = snapshot.clipboard_read_seq,
            .bracketed_paste = snapshot.bracketed_paste,
            .foreground_available = snapshot.foreground_available,
            .foreground_pgid = snapshot.foreground_pgid,
        };
        errdefer next.deinit(allocator);
        // Staged session-host preparation seals actual backing extents, not merely semantic
        // lengths. Precise allocation here makes every cache produced by the common path canonical
        // without adding a session-host-only normalization copy later. Zero length remains the
        // allocation-free `.empty` representation.
        next.cwd = try exactOwnedCopy(u8, allocator, snapshot.cwd);
        next.cwd_host = try exactOwnedCopy(u8, allocator, snapshot.cwd_host); // cwd와 같은 트랜잭션에서만 갱신(쌍 유지)
        next.window_title = try exactOwnedCopy(u8, allocator, snapshot.window_title);
        if (snapshot.ssh_remote_dest) |dest|
            next.ssh_remote_dest = try exactOwnedCopy(u8, allocator, dest);
        next.clipboard_read_target = try exactOwnedCopy(u8, allocator, snapshot.clipboard_read_target);
        next.foreground_processes = try exactOwnedCopy(
            pty.types.ForegroundProcessName,
            allocator,
            snapshot.foreground_processes,
        );
        next.agent_progress = try exactOwnedCopy(
            u8,
            allocator,
            if (snapshot.agent_progress.len != 0)
                snapshot.agent_progress
            else
                self.agent_progress.items,
        );
        self.deinit(allocator);
        self.* = next;
    }

    fn exactOwnedCopy(
        comptime T: type,
        allocator: std.mem.Allocator,
        source: []const T,
    ) !std.ArrayListUnmanaged(T) {
        var out: std.ArrayListUnmanaged(T) = .empty;
        errdefer out.deinit(allocator);
        if (source.len == 0) return out;
        try out.ensureTotalCapacityPrecise(allocator, source.len);
        out.appendSliceAssumeCapacity(source);
        return out;
    }

    /// 캐시(소유 버퍼)를 호출 동안만 유효한 view로 편다.
    ///
    /// **스칼라 필드는 `inline for`로 자동 복사한다.** 예전엔 필드를 하나씩 손으로 나열했는데, 새 관측 필드를
    /// 추가하고 여기 한 줄을 빠뜨리면 struct 기본값(0/false)이 조용히 남아 **그 기능이 제품에서 통째로 무동작**했다
    /// (mouse_tracking_mode·bell_count·clipboard_* 가 실제로 그렇게 죽어 있었고, 테스트가 `term.rt.observation.*`를
    /// 직접 대입해 이 계층을 건너뛰는 바람에 CI도 못 잡았다). 이름과 타입이 같은 필드는 자동으로 실리므로 같은
    /// 누락이 구조적으로 불가능하다. 표현이 다른 필드(ArrayList→slice, optional 표현)만 아래에서 명시한다.
    pub fn view(self: *const RuntimeObservation) RuntimeObservationView {
        var out: RuntimeObservationView = .{
            // 표현이 다른 필드(소유 버퍼 → 빌린 슬라이스, present 플래그 → optional)만 수동이다.
            .cwd = self.cwd.items,
            .cwd_host = self.cwd_host.items,
            .window_title = self.window_title.items,
            .ssh_remote_dest = if (self.ssh_remote_dest_present) self.ssh_remote_dest.items else null,
            .clipboard_read_target = self.clipboard_read_target.items,
            .foreground_processes = self.foreground_processes.items,
            .agent_progress = self.agent_progress.items,
        };
        inline for (@typeInfo(RuntimeObservationView).@"struct".fields) |field| {
            if (@hasField(RuntimeObservation, field.name)) {
                const Src = @TypeOf(@field(self, field.name));
                if (Src == field.type) @field(out, field.name) = @field(self, field.name);
            }
        }
        return out;
    }

    /// 1회성 progress를 소비하고 backing도 함께 버린다. 빈 owned slice는 canonical `.empty`여야
    /// staged session-host preparation이 semantic length와 실제 backing extent를 같은 값으로 seal할 수 있다.
    pub fn clearAgentProgress(self: *RuntimeObservation, allocator: std.mem.Allocator) void {
        self.agent_progress.deinit(allocator);
        self.agent_progress = .empty;
    }
};

/// 새 terminal runtime을 만들 때 필요한 입력. `handle`은 caller(GUI)가 앱 전역 allocator에서 발급해 넘긴다 —
/// backend가 발급하지 않는 이유는 in-process에서 handle이 곧 surface_id이고, surface_id 발급은 GUI layout(창 트리
/// 정책)의 책임이기 때문이다(P3 host backend는 host가 발급한 runtime_id를 이 자리에 다시 매핑한다).
pub const SpawnParams = struct {
    handle: RuntimeHandle,
    /// 셸/argv/cwd/env/login 등 프로세스 스펙. `pane_id`는 caller가 handle과 같은 값으로 채운다(control-plane self selector).
    request: pty.SpawnRequest,
    /// 초기 grid 크기. `request.size`와 별도로 받는다 — createTerm이 창 레이아웃에서 계산한 pane 크기를 쓰기 때문.
    size: terminal.Size,
    /// PTY→core 출력 이벤트 큐 용량(bounded).
    queue_capacity: usize,
    /// reader가 첫 child output을 parse하기 전에 적용할 runtime config. local GUI와 remote spawn wire가 같은 값
    /// snapshot을 사용하며, null은 기존 caller의 기본 설정 의미다.
    initial_config: ?core_command.RuntimeConfig = null,
};

/// backend 구현이 채워 넣는 함수 표. 모든 함수의 첫 인자는 `ctx`(구현 인스턴스)다. 에러는 `anyerror`로 둔다 —
/// in-process는 `RuntimeError || Thread.SpawnError || 프로세스 spawn 오류`, 원격 host는 transport 오류라 구현마다
/// 에러 집합이 달라서, vtable 고정 시그니처는 `anyerror`가 유일하게 맞는 선택이다(PtyIo도 `anyerror`를 쓴다).
pub const VTable = struct {
    /// terminal runtime(PTY + 셸)을 만든다. 반환값은 그 runtime에 붙은 **복구 가능한 `Surface`**(그리드/스크롤백/
    /// 메타)의 안정 포인터다 — GUI는 이 포인터를 `Term.surface`로 참조만 하고(소유는 backend), config 설정(스크롤백
    /// arena/palette 등)을 여기에 적용한다. live PTY handle은 반환하지 않는다(그것이 seam 목표). 아직 `attach`
    /// 전이라 output 처리는 시작되지 않는다.
    spawn: *const fn (ctx: *anyopaque, params: SpawnParams) anyerror!*surface_mod.Surface,

    /// runtime의 PTY를 그 surface에 연결해 output 처리를 시작한다. `process_in_reader=true`(interactive 셸)면
    /// reader가 output을 코어에 직접 반영하고 메인 입력을 write 큐로 라우팅한다(docs/io-render-threading.md PR3).
    attach: *const fn (ctx: *anyopaque, handle: RuntimeHandle, process_in_reader: bool) anyerror!runtime_mod.RuntimeLink,

    /// 이 runtime의 이벤트 펌프. 호출자(frame loop)가 `drainAvailable`로 output/exit를 surface에 반영한다.
    pump: *const fn (ctx: *anyopaque, handle: RuntimeHandle) anyerror!runtime_pump.RuntimeEventPump,

    /// 이미 terminal input으로 분류된 bytes를 runtime PTY로 보낸다(keybinding 해석 없음 — app/config 책임).
    write_input: *const fn (ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void,

    /// 지금 쓸 수 있는 만큼만 쓰고 쓴 길이를 돌려준다(paste가 UI tick을 동결시키지 않게). 0=다음 tick 재시도.
    write_input_nonblocking: *const fn (ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize,

    /// 메인발 코어 mutate(스크롤/선택/IME 등)를 reader 스레드로 위임한다(docs/io-render-threading.md §9 Phase 3).
    enqueue_core_command: *const fn (ctx: *anyopaque, handle: RuntimeHandle, cmd: core_command.CoreCommand, io: std.Io) anyerror!void,

    /// grid 크기를 바꾼다 — 코어 resize와 PTY winsize(`TIOCSWINSZ`)를 한 user action으로 함께 적용한다.
    resize: *const fn (ctx: *anyopaque, handle: RuntimeHandle, size: terminal.Size, io: std.Io) anyerror!void,

    /// runtime routing을 끊고(late output 거부) PTY/자식/reader를 종료한다. 멱등 — 실제 탭/창 close의 수명 경계.
    close_and_detach: *const fn (ctx: *anyopaque, handle: RuntimeHandle) void,

    /// PTY/자식/reader를 종료하되 runtime routing detach는 하지 않는다(routing이 이미 없는 조기 실패/앱 종료 경로).
    close: *const fn (ctx: *anyopaque, handle: RuntimeHandle) void,

    /// exit/read_error 관측 후 reader join + 큐 close로 마무리한다. `close`와 달리 "이미 종료가 관측된" 경로용.
    finish_after_termination: *const fn (ctx: *anyopaque, handle: RuntimeHandle) void,

    /// runtime의 소유 슬롯(surface + live PTY 번들)을 해제한다. `close_and_detach`/`close`로 종료를 끝낸 뒤 부른다.
    /// 이 호출 뒤 handle과 `spawn`이 돌려준 surface 포인터는 무효다(dangling — 이후 접근 금지).
    remove: *const fn (ctx: *anyopaque, handle: RuntimeHandle) void,

    /// 포그라운드 process group id(agent observer용). runtime이 없거나 PTY가 없으면 null. 관통 관측이지 제어가 아니다.
    foreground_process_group: *const fn (ctx: *anyopaque, handle: RuntimeHandle) ?i32,

    /// 이 runtime의 프로세스 트리(셸 + 자손)의 자원 표본을 `out`에 채우고 개수를 돌려준다.
    /// 상태바 리소스 항목이 쓴다(docs/status-bar.md §6). 고정 버퍼라 alloc 없음.
    ///
    /// **이 seam으로 넘기는 이유**: pid·libproc을 `app_session`이 직접 만지지 않게 한다. 그리고 host-backed
    /// 터미널은 PTY가 host 프로세스 안에 있어 앱에서 트리를 훑을 수 없는데, 그 구현이 나중에 같은 함수를
    /// 채우면 끝난다 — 지금 app_session에서 훑어 두면 그때 다시 뜯어야 한다.
    /// 표본을 못 얻으면 0(항목이 안 뜬다 — 0을 그리면 "0 바이트를 쓰는 중"으로 읽힌다).
    resource_samples: *const fn (ctx: *anyopaque, handle: RuntimeHandle, out: []resource_usage.Sample) usize,

    /// 포그라운드 프로세스 이름들을 `out`에 채우고 채운 개수를 돌려준다(agent kind 분류용). 고정 버퍼라 alloc 없음.
    foreground_process_names: *const fn (ctx: *anyopaque, handle: RuntimeHandle, out: []pty.types.ForegroundProcessName) usize,

    /// 이 터미널이 **서 있는 폴더**를 OS에 직접 물어 `out`에 채운다. 못 얻으면 null(자른 경로는 절대 돌려주지 않는다).
    ///
    /// **왜 `read_observation`과 별개인가**: observation의 cwd는 OSC 7(셸이 보고)이 출처라 셸 통합이 없거나
    /// (bash/fish) 전체화면 TUI가 RIS로 화면을 리셋하면 비어 버린다. 이건 그 빈칸을 커널 조회로 메우는
    /// **폴백 질의**다. observation 경로에 넣으면 ⑴ 관측 캐시가 title generation으로 early-return해 정작
    /// 필요한 순간 안 돌고 ⑵ 매 프레임 syscall이 된다 — 그래서 호출자가 필요할 때만 부르는 별도 seam이다.
    ///
    /// **이 seam으로 넘기는 이유**는 `resource_samples`와 같다: pid·libproc을 `app_session`이 직접 만지지 않게 한다.
    /// host-backed 터미널은 PTY가 host 프로세스에 있어 앱에서 조회할 수 없고, 그 구현은 null을 돌려준다.
    process_cwd: *const fn (ctx: *anyopaque, handle: RuntimeHandle, out: []u8) ?[]const u8,

    /// cwd/title/semantic/SSH destination/foreground를 한 시점에 caller-owned cache로 복사한다. `include_foreground=false`면
    /// 구현은 비싼 OS process 열거를 생략할 수 있다. unavailable은 empty와 구분해 `out.availability`에 기록한다.
    read_observation: *const fn (ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *RuntimeObservation, include_foreground: bool) anyerror!void,

    /// 보안·라우팅 결정을 내리기 직전에 backend SSOT와 동기화하는 barrier. in-process는 즉시 core를 읽고, remote는
    /// host RPC가 observation base/revision을 전진시킨 응답을 받은 뒤 caller-owned cache를 교체한다.
    refresh_observation: *const fn (ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *RuntimeObservation, include_foreground: bool) anyerror!void,

    /// agent observer가 쓰는 bounded 최근 화면 텍스트. in-process는 host/core를 lock-copy하고 remote는 이미 조립된
    /// RemoteScreen을 읽는다. 반환은 caller 소유이며 raw PTY bytes를 wire에 새로 싣지 않는다.
    dump_recent_text: *const fn (ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, max_rows: usize, max_bytes: usize) anyerror![]u8,
};

/// GUI layout이 terminal runtime을 다루는 유일한 표면. `ctx`+`vtable`로 in-process/원격 host 구현을 같은 계약
/// 뒤에 둔다. 값 타입(포인터 두 개)이라 복사가 싸고 `Term`이 직접 들거나 `AppSession`이 하나 들고 handle로 라우팅해도 된다.
pub const TermRuntimeBackend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn spawn(self: TermRuntimeBackend, params: SpawnParams) anyerror!*surface_mod.Surface {
        return self.vtable.spawn(self.ctx, params);
    }

    pub fn attach(self: TermRuntimeBackend, handle: RuntimeHandle, process_in_reader: bool) anyerror!runtime_mod.RuntimeLink {
        return self.vtable.attach(self.ctx, handle, process_in_reader);
    }

    pub fn pump(self: TermRuntimeBackend, handle: RuntimeHandle) anyerror!runtime_pump.RuntimeEventPump {
        return self.vtable.pump(self.ctx, handle);
    }

    pub fn writeInput(self: TermRuntimeBackend, handle: RuntimeHandle, bytes: []const u8) anyerror!void {
        return self.vtable.write_input(self.ctx, handle, bytes);
    }

    pub fn writeInputNonBlocking(self: TermRuntimeBackend, handle: RuntimeHandle, bytes: []const u8) anyerror!usize {
        return self.vtable.write_input_nonblocking(self.ctx, handle, bytes);
    }

    pub fn enqueueCoreCommand(self: TermRuntimeBackend, handle: RuntimeHandle, cmd: core_command.CoreCommand, io: std.Io) anyerror!void {
        return self.vtable.enqueue_core_command(self.ctx, handle, cmd, io);
    }

    pub fn resize(self: TermRuntimeBackend, handle: RuntimeHandle, size: terminal.Size, io: std.Io) anyerror!void {
        return self.vtable.resize(self.ctx, handle, size, io);
    }

    pub fn closeAndDetach(self: TermRuntimeBackend, handle: RuntimeHandle) void {
        self.vtable.close_and_detach(self.ctx, handle);
    }

    pub fn close(self: TermRuntimeBackend, handle: RuntimeHandle) void {
        self.vtable.close(self.ctx, handle);
    }

    pub fn finishAfterTermination(self: TermRuntimeBackend, handle: RuntimeHandle) void {
        self.vtable.finish_after_termination(self.ctx, handle);
    }

    pub fn remove(self: TermRuntimeBackend, handle: RuntimeHandle) void {
        self.vtable.remove(self.ctx, handle);
    }

    pub fn foregroundProcessGroup(self: TermRuntimeBackend, handle: RuntimeHandle) ?i32 {
        return self.vtable.foreground_process_group(self.ctx, handle);
    }

    pub fn foregroundProcessNames(self: TermRuntimeBackend, handle: RuntimeHandle, out: []pty.types.ForegroundProcessName) usize {
        return self.vtable.foreground_process_names(self.ctx, handle, out);
    }

    pub fn resourceSamples(self: TermRuntimeBackend, handle: RuntimeHandle, out: []resource_usage.Sample) usize {
        return self.vtable.resource_samples(self.ctx, handle, out);
    }

    pub fn processCwd(self: TermRuntimeBackend, handle: RuntimeHandle, out: []u8) ?[]const u8 {
        return self.vtable.process_cwd(self.ctx, handle, out);
    }

    pub fn readObservation(self: TermRuntimeBackend, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *RuntimeObservation, include_foreground: bool) anyerror!void {
        return self.vtable.read_observation(self.ctx, handle, allocator, out, include_foreground);
    }

    pub fn refreshObservation(self: TermRuntimeBackend, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *RuntimeObservation, include_foreground: bool) anyerror!void {
        return self.vtable.refresh_observation(self.ctx, handle, allocator, out, include_foreground);
    }

    pub fn dumpRecentText(self: TermRuntimeBackend, handle: RuntimeHandle, allocator: std.mem.Allocator, max_rows: usize, max_bytes: usize) anyerror![]u8 {
        return self.vtable.dump_recent_text(self.ctx, handle, allocator, max_rows, max_bytes);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Fake backend + 계약 단위 테스트
//
// 이 테스트들이 증명하는 것(그리고 터미널에서 왜 중요한가): P2 seam의 핵심 약속은 "GUI가 `*LivePtySession`을
// 직접 들지 않고 `TermRuntimeBackend` 계약 + opaque handle만으로 terminal runtime 하나의 수명 전체(spawn →
// attach → input/resize → terminate)를 몰고, detach 뒤에는 죽은 runtime으로 가는 입력이 거부된다"는 것이다.
// 이 계약이 실제 PTY 없이도 성립함을 fake backend로 고정한다 — 실 PTY(macOS) 경로는 in-process adapter의 별도
// 통합 테스트가 검증하고, 여기서는 순수 Zig로 계약 표면(라우팅·수명·late-event)만 본다.
//
// fake는 실제 `SurfaceRuntime`을 재사용해 라우팅을 진짜로 검증한다(빈 목킹이 아니다). PTY만 `FakeBackendPty`
// (writes 기록 더블)로 대체한다.
// ─────────────────────────────────────────────────────────────────────────────

/// fake backend 안에서 한 runtime을 대신하는 최소 상태. 실제 PTY 대신 입력 bytes를 기록하고, output 이벤트 큐
/// 하나를 소유해 `pump`가 유효한 `RuntimeEventPump`를 돌려줄 수 있게 한다.
const FakeBackendRuntime = struct {
    surface: *surface_mod.Surface,
    writes: std.ArrayList(u8) = .empty,
    resized_to: ?terminal.Size = null,
    attached: bool = false,
    detached: bool = false,
    closed: bool = false,

    fn writeInput(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FakeBackendRuntime = @ptrCast(@alignCast(ctx));
        try self.writes.appendSlice(std.testing.allocator, bytes);
    }

    fn resizeIo(ctx: *anyopaque, size: terminal.Size) anyerror!void {
        const self: *FakeBackendRuntime = @ptrCast(@alignCast(ctx));
        self.resized_to = size;
    }

    fn ptyIo(self: *FakeBackendRuntime) runtime_mod.PtyIo {
        return .{ .ctx = self, .write_input = writeInput, .resize_fn = resizeIo };
    }
};

/// 테스트 전용 in-memory backend. 계약 vtable을 실제 `SurfaceRuntime` 라우팅 + `FakeBackendRuntime` PTY 더블로
/// 구현한다. handle → runtime 매핑은 작은 선형 리스트(테스트 규모라 충분).
const FakeTermBackend = struct {
    allocator: std.mem.Allocator,
    runtime: runtime_mod.SurfaceRuntime,
    entries: std.ArrayList(Entry) = .empty,
    /// `process_cwd`가 돌려줄 값(테스트가 세팅). 실 backend에서는 커널이 주는 값이라 여기서만 흉내낸다.
    fake_process_cwd: []const u8 = "",

    const Entry = struct { handle: RuntimeHandle, rt: *FakeBackendRuntime };

    const vtable = VTable{
        .spawn = spawn,
        .attach = attach,
        .pump = pump,
        .write_input = writeInput,
        .write_input_nonblocking = writeInputNonBlocking,
        .enqueue_core_command = enqueueCoreCommand,
        .resize = resize,
        .close_and_detach = closeAndDetach,
        .close = close,
        .finish_after_termination = finishAfterTermination,
        .remove = remove,
        .foreground_process_group = foregroundProcessGroup,
        .resource_samples = resourceSamples,
        .foreground_process_names = foregroundProcessNames,
        .process_cwd = processCwd,
        .read_observation = readObservation,
        .refresh_observation = readObservation,
        .dump_recent_text = dumpRecentText,
    };

    fn init(allocator: std.mem.Allocator) FakeTermBackend {
        return .{ .allocator = allocator, .runtime = runtime_mod.SurfaceRuntime.init(allocator) };
    }

    fn deinit(self: *FakeTermBackend) void {
        for (self.entries.items) |e| {
            e.rt.writes.deinit(self.allocator);
            e.rt.surface.deinit();
            self.allocator.destroy(e.rt.surface);
            self.allocator.destroy(e.rt);
        }
        self.entries.deinit(self.allocator);
        self.runtime.deinit();
    }

    fn backend(self: *FakeTermBackend) TermRuntimeBackend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn find(self: *FakeTermBackend, handle: RuntimeHandle) ?*FakeBackendRuntime {
        for (self.entries.items) |e| if (e.handle == handle) return e.rt;
        return null;
    }

    fn spawn(ctx: *anyopaque, params: SpawnParams) anyerror!*surface_mod.Surface {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        const surface = try self.allocator.create(surface_mod.Surface);
        errdefer self.allocator.destroy(surface);
        surface.* = try surface_mod.Surface.init(self.allocator, params.handle, params.size);
        errdefer surface.deinit();
        const rt = try self.allocator.create(FakeBackendRuntime);
        errdefer self.allocator.destroy(rt);
        rt.* = .{ .surface = surface };
        try self.entries.append(self.allocator, .{ .handle = params.handle, .rt = rt });
        return surface;
    }

    fn attach(ctx: *anyopaque, handle: RuntimeHandle, process_in_reader: bool) anyerror!runtime_mod.RuntimeLink {
        _ = process_in_reader;
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        const rt = self.find(handle) orelse return error.UnknownSurface;
        const link = try self.runtime.attach(rt.surface, handle, rt.ptyIo());
        rt.attached = true;
        return link;
    }

    fn pump(ctx: *anyopaque, handle: RuntimeHandle) anyerror!runtime_pump.RuntimeEventPump {
        _ = ctx;
        _ = handle;
        // fake는 실제 이벤트 큐를 돌리지 않는다(계약 표면 검증용). pump 형태를 갖추는 실 drain 검증은 실 PTY를
        // 쓰는 in-process adapter 통합 테스트가 맡는다. 이 계약 테스트는 spawn/attach/input/resize/terminate만 본다.
        return error.Unsupported;
    }

    fn writeInput(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.writeInput(handle, .{ .bytes = bytes });
    }

    fn writeInputNonBlocking(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.writeInputNonBlocking(handle, bytes);
    }

    fn enqueueCoreCommand(ctx: *anyopaque, handle: RuntimeHandle, cmd: core_command.CoreCommand, io: std.Io) anyerror!void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.enqueueCoreCommand(handle, cmd, io);
    }

    fn resize(ctx: *anyopaque, handle: RuntimeHandle, size: terminal.Size, io: std.Io) anyerror!void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.resize(handle, size, io);
    }

    fn closeAndDetach(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        if (self.find(handle)) |rt| {
            self.runtime.detachSurface(handle);
            rt.detached = true;
            rt.closed = true;
        }
    }

    fn close(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        if (self.find(handle)) |rt| rt.closed = true;
    }

    fn finishAfterTermination(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        if (self.find(handle)) |rt| rt.closed = true;
    }

    fn remove(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        for (self.entries.items, 0..) |e, i| {
            if (e.handle == handle) {
                e.rt.writes.deinit(self.allocator);
                e.rt.surface.deinit();
                self.allocator.destroy(e.rt.surface);
                self.allocator.destroy(e.rt);
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }

    fn foregroundProcessGroup(ctx: *anyopaque, handle: RuntimeHandle) ?i32 {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        // fake는 프로세스가 없으니 handle이 살아 있으면 고정 pgid, 없으면 null을 돌려 관측 계약의 유무 분기를 검증한다.
        return if (self.find(handle) != null) @as(i32, 4242) else null;
    }

    fn foregroundProcessNames(ctx: *anyopaque, handle: RuntimeHandle, out: []pty.types.ForegroundProcessName) usize {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        if (self.find(handle) == null or out.len == 0) return 0;
        out[0] = .{ .pid = 1, .len = 0 };
        return 1;
    }

    /// 테스트가 주입한 커널 cwd를 그대로 돌려준다(실 프로세스가 없으므로 조회 자체는 흉내낼 수 없다).
    /// `fake_process_cwd`가 비면 null — "OSC 7도 없고 커널도 모른다"는 경우를 표현한다.
    fn processCwd(ctx: *anyopaque, handle: RuntimeHandle, out: []u8) ?[]const u8 {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        if (self.find(handle) == null) return null;
        if (self.fake_process_cwd.len == 0 or self.fake_process_cwd.len > out.len) return null;
        @memcpy(out[0..self.fake_process_cwd.len], self.fake_process_cwd);
        return out[0..self.fake_process_cwd.len];
    }

    /// 테스트용 고정 표본 — 실 프로세스가 없으므로 "표본 하나가 온다"는 배관만 증명한다.
    fn resourceSamples(ctx: *anyopaque, handle: RuntimeHandle, out: []resource_usage.Sample) usize {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        if (self.find(handle) == null or out.len == 0) return 0;
        out[0] = .{ .pid = 1, .footprint_bytes = 1024 * 1024, .cpu_ns = 1_000_000 };
        return 1;
    }

    fn readObservation(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *RuntimeObservation, include_foreground: bool) anyerror!void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        const rt = self.find(handle) orelse return error.UnknownSurface;
        var names: [1]pty.types.ForegroundProcessName = undefined;
        const count = if (include_foreground) foregroundProcessNames(ctx, handle, &names) else 0;
        try out.replace(allocator, .{
            .availability = .current,
            .revision = rt.surface.core.observerGeneration(),
            .observer_generation = rt.surface.core.observerGeneration(),
            .title_generation = rt.surface.core.title_generation.load(.monotonic),
            .size = rt.surface.core.size,
            .cwd = rt.surface.core.currentCwd(),
            .cwd_host = rt.surface.core.currentCwdHost(),
            .window_title = rt.surface.core.windowTitle(),
            .ssh_remote_dest = rt.surface.core.sshRemoteDest(),
            .semantic_state = rt.surface.core.semantic_state,
            .alt_active = rt.surface.core.alt_active,
            .app_cursor_keys = rt.surface.core.application_cursor_keys,
            .app_keypad = rt.surface.core.application_keypad,
            .kitty_flags = rt.surface.core.kitty_flags.current().int(),
            .alternate_scroll = rt.surface.core.alternate_scroll,
            .foreground_available = include_foreground,
            .foreground_pgid = if (include_foreground) 4242 else out.foreground_pgid,
            .foreground_processes = if (include_foreground) names[0..count] else out.foreground_processes.items,
        });
    }

    fn dumpRecentText(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, max_rows: usize, max_bytes: usize) anyerror![]u8 {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        const rt = self.find(handle) orelse return error.UnknownSurface;
        return rt.surface.core.dumpRecentTextUtf8(allocator, max_rows, max_bytes);
    }
};

test "term runtime backend: fake drives spawn/attach/input/resize through the contract only" {
    const allocator = std.testing.allocator;
    var fake = FakeTermBackend.init(allocator);
    defer fake.deinit();
    const be = fake.backend();

    // spawn: GUI는 handle과 반환된 *Surface만 받는다(*LivePtySession 없음).
    const surface = try be.spawn(.{
        .handle = 7,
        .request = .{ .command = "/bin/sh" },
        .size = .{ .cols = 20, .rows = 4 },
        .queue_capacity = 8,
    });
    try std.testing.expectEqual(@as(u64, 7), surface.id);

    // attach: routing이 계약을 통해 붙는다.
    _ = try be.attach(7, false);

    // input: handle로 보낸 bytes가 그 runtime의 PTY 더블에 도달한다.
    try be.writeInput(7, "echo hi\n");
    const rt = fake.find(7).?;
    try std.testing.expectEqualStrings("echo hi\n", rt.writes.items);

    // resize: 코어와 PTY(더블) 둘 다 계약을 통해 갱신된다.
    try be.resize(7, .{ .cols = 40, .rows = 10 }, std.testing.io);
    try std.testing.expectEqual(@as(u16, 40), surface.core.size.cols);
    try std.testing.expect(rt.resized_to != null);
    try std.testing.expectEqual(@as(u16, 40), rt.resized_to.?.cols);

    // 관측: 살아 있는 handle은 pgid/이름을 돌려준다(관통 관측 계약).
    try std.testing.expectEqual(@as(?i32, 4242), be.foregroundProcessGroup(7));
    var names: [4]pty.types.ForegroundProcessName = undefined;
    try std.testing.expectEqual(@as(usize, 1), be.foregroundProcessNames(7, &names));
}

test "term runtime backend: processCwd는 계약을 통해서만 오고 모르는 handle·좁은 버퍼는 null이다" {
    // 이 seam이 왜 있는가: OSC 7(셸 보고)이 유일한 cwd 출처면 bash/fish 셸이나 화면을 리셋하는 TUI(claude·codex)
    // 아래에서 "이 터미널이 어느 폴더에 있는가"를 영영 모르게 된다. 그 빈칸을 커널 조회로 메우는 폴백이고,
    // 여기서는 **계약 표면**(handle 라우팅·실패 시 null·자르지 않음)만 고정한다. 실제 조회는 pty/macos.zig가 한다.
    const allocator = std.testing.allocator;
    var fake = FakeTermBackend.init(allocator);
    defer fake.deinit();
    fake.fake_process_cwd = "/Users/me/work/repo";
    const be = fake.backend();

    _ = try be.spawn(.{
        .handle = 11,
        .request = .{ .command = "/bin/sh" },
        .size = .{ .cols = 10, .rows = 3 },
        .queue_capacity = 4,
    });

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/Users/me/work/repo", be.processCwd(11, &buf).?);

    // 모르는 handle은 살아 있는 다른 runtime의 cwd로 새지 않는다 — 새면 남의 저장소 상태를 보여 주게 된다.
    try std.testing.expect(be.processCwd(999, &buf) == null);

    // **자르지 않는다.** 잘린 경로는 조용히 상위 디렉터리를 가리켜 다른 저장소를 잡는다.
    var tiny: [4]u8 = undefined;
    try std.testing.expect(be.processCwd(11, &tiny) == null);

    // 커널도 모르는 경우(원격 runtime 등)는 null이고, 호출자는 OSC 7 값으로 남는다.
    fake.fake_process_cwd = "";
    try std.testing.expect(be.processCwd(11, &buf) == null);
}

test "term runtime backend: closeAndDetach through the contract rejects late input" {
    const allocator = std.testing.allocator;
    var fake = FakeTermBackend.init(allocator);
    defer fake.deinit();
    const be = fake.backend();

    _ = try be.spawn(.{
        .handle = 3,
        .request = .{ .command = "/bin/sh" },
        .size = .{ .cols = 10, .rows = 3 },
        .queue_capacity = 4,
    });
    _ = try be.attach(3, false);
    try be.writeInput(3, "before");

    // terminate: routing을 끊는다. 이후 같은 handle로 온 입력은 살아 있는 다른 surface로 새지 않고 거부된다.
    be.closeAndDetach(3);
    try std.testing.expectError(error.UnknownSurface, be.writeInput(3, "late"));

    // 죽은 handle의 관측은 null/0(없음)을 돌려준다.
    try std.testing.expectEqual(@as(?i32, null), be.foregroundProcessGroup(999));
}

test "term runtime backend: unknown handle attach is rejected, not routed to another runtime" {
    const allocator = std.testing.allocator;
    var fake = FakeTermBackend.init(allocator);
    defer fake.deinit();
    const be = fake.backend();

    _ = try be.spawn(.{
        .handle = 1,
        .request = .{ .command = "/bin/sh" },
        .size = .{ .cols = 8, .rows = 2 },
        .queue_capacity = 2,
    });
    // 존재하지 않는 handle을 attach하면 다른 runtime에 잘못 붙지 않고 거부된다.
    try std.testing.expectError(error.UnknownSurface, be.attach(2, false));
}

test "C3-3b2b0 runtime observation replacement owns strings and preserves unconsumed progress" {
    const allocator = std.testing.allocator;
    var observation: RuntimeObservation = .{};
    defer observation.deinit(allocator);

    var cwd = [_]u8{ '/', 'o', 'l', 'd' };
    var process = pty.types.ForegroundProcessName{ .pid = 77, .len = 6 };
    @memcpy(process.bytes[0..6], "claude");
    try observation.replace(allocator, .{
        .availability = .current,
        .revision = 1,
        .cwd = &cwd,
        .window_title = "first",
        .ssh_remote_dest = "box",
        .foreground_available = true,
        .foreground_pgid = 77,
        .foreground_processes = &.{process},
        .agent_progress = "waiting",
    });
    cwd[1] = 'X'; // source 수명이 끝나거나 바뀌어도 cache는 독립 owned copy다.
    try std.testing.expectEqualStrings("/old", observation.cwd.items);
    try std.testing.expectEqualStrings("claude", observation.foreground_processes.items[0].slice());
    try expectObservationOwnedCapacitiesExact(&observation);

    // stable metadata poll의 빈 progress는 아직 observer가 소비하지 않은 1회성 값을 지우지 않는다.
    try observation.replace(allocator, .{
        .availability = .current,
        .revision = 2,
        .cwd = "/new",
        .window_title = "second",
    });
    try std.testing.expectEqualStrings("/new", observation.cwd.items);
    try std.testing.expectEqualStrings("waiting", observation.agent_progress.items);
    try expectObservationOwnedCapacitiesExact(&observation);
    observation.clearAgentProgress(allocator);
    try std.testing.expectEqual(@as(usize, 0), observation.agent_progress.items.len);
    try std.testing.expectEqual(@as(usize, 0), observation.agent_progress.capacity);
}

test "C3-3b2b0 runtime observation every replacement allocation failure preserves the previous coherent snapshot" {
    const allocator = std.testing.allocator;
    var process = pty.types.ForegroundProcessName{ .pid = 99, .len = 5 };
    @memcpy(process.bytes[0..5], "codex");
    const next: RuntimeObservationView = .{
        .availability = .current,
        .revision = 2,
        .observer_generation = 22,
        .title_generation = 3,
        .size = .{ .cols = 120, .rows = 40 },
        .cwd = "/next",
        .cwd_host = "next-host",
        .window_title = "next title",
        .ssh_remote_dest = "next-box",
        .semantic_state = .command,
        .alt_active = true,
        .app_cursor_keys = true,
        .app_keypad = true,
        .kitty_flags = 3,
        .alternate_scroll = false,
        .mouse_tracking = true,
        .mouse_tracking_mode = 4,
        .bracketed_paste = true,
        .bell_count = 8,
        .clipboard_write_seq = 9,
        .clipboard_read_seq = 10,
        .clipboard_read_target = "c",
        .foreground_available = true,
        .foreground_pgid = 99,
        .foreground_processes = &.{process},
        .agent_progress = "running",
    };

    // 먼저 실제 allocation 수를 센 뒤 모든 fail index를 순회한다. 성공 경로 임시 cache는 같은 wrapper allocator로 해제한다.
    var counting = std.testing.FailingAllocator.init(allocator, .{});
    var counted: RuntimeObservation = .{};
    try counted.replace(counting.allocator(), next);
    const allocation_count = counting.alloc_index;
    counted.deinit(counting.allocator());
    try std.testing.expect(allocation_count > 0);

    for (0..allocation_count) |fail_index| {
        var observation: RuntimeObservation = .{};
        defer observation.deinit(allocator);
        const old: RuntimeObservationView = .{
            .availability = .current,
            .revision = 1,
            .observer_generation = 11,
            .title_generation = 1,
            .size = .{ .cols = 80, .rows = 24 },
            .cwd = "/old",
            .cwd_host = "old-host",
            .window_title = "old title",
            .ssh_remote_dest = "old-box",
            .semantic_state = .prompt,
            .alt_active = true,
            .app_cursor_keys = true,
            .app_keypad = true,
            .kitty_flags = 5,
            .alternate_scroll = false,
            .mouse_tracking = true,
            .mouse_tracking_mode = 3,
            .bracketed_paste = true,
            .bell_count = 18,
            .clipboard_write_seq = 19,
            .clipboard_read_seq = 20,
            .clipboard_read_target = "p",
            .foreground_available = true,
            .foreground_pgid = 77,
            .foreground_processes = &.{process},
            .agent_progress = "waiting",
        };
        try observation.replace(allocator, old);
        const cwd_ptr = observation.cwd.items.ptr;
        const cwd_host_ptr = observation.cwd_host.items.ptr;
        const title_ptr = observation.window_title.items.ptr;
        const ssh_ptr = observation.ssh_remote_dest.items.ptr;
        const clipboard_ptr = observation.clipboard_read_target.items.ptr;
        const processes_ptr = observation.foreground_processes.items.ptr;
        const progress_ptr = observation.agent_progress.items.ptr;

        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, observation.replace(failing.allocator(), next));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqualDeep(old, observation.view());
        try expectObservationOwnedCapacitiesExact(&observation);
        try std.testing.expectEqual(cwd_ptr, observation.cwd.items.ptr);
        try std.testing.expectEqual(cwd_host_ptr, observation.cwd_host.items.ptr);
        try std.testing.expectEqual(title_ptr, observation.window_title.items.ptr);
        try std.testing.expectEqual(ssh_ptr, observation.ssh_remote_dest.items.ptr);
        try std.testing.expectEqual(clipboard_ptr, observation.clipboard_read_target.items.ptr);
        try std.testing.expectEqual(processes_ptr, observation.foreground_processes.items.ptr);
        try std.testing.expectEqual(progress_ptr, observation.agent_progress.items.ptr);
    }

    // 빈 incoming progress도 old progress를 재소유하므로 그 별도 allocation ordinal 전부에서 같은 원자성을 요구한다.
    var preserved_progress_next = next;
    preserved_progress_next.agent_progress = "";
    var preserved_counting = std.testing.FailingAllocator.init(allocator, .{});
    var preserved_counted: RuntimeObservation = .{};
    try preserved_counted.replace(preserved_counting.allocator(), .{ .agent_progress = "old-progress" });
    const preserved_baseline = preserved_counting.alloc_index;
    try preserved_counted.replace(preserved_counting.allocator(), preserved_progress_next);
    const preserved_allocation_count = preserved_counting.alloc_index - preserved_baseline;
    preserved_counted.deinit(preserved_counting.allocator());
    for (0..preserved_allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = preserved_baseline + fail_index });
        var observation: RuntimeObservation = .{};
        defer observation.deinit(failing.allocator());
        try observation.replace(failing.allocator(), .{ .agent_progress = "old-progress" });
        try std.testing.expectError(error.OutOfMemory, observation.replace(failing.allocator(), preserved_progress_next));
        try std.testing.expectEqualStrings("old-progress", observation.agent_progress.items);
        try expectObservationOwnedCapacitiesExact(&observation);
    }
}

test "C3-3b2b0 runtime observation uses canonical empty and exact near-capacity owners" {
    const host_protocol = @import("../session/host_protocol.zig");
    const allocator = std.testing.allocator;

    var empty: RuntimeObservation = .{};
    defer empty.deinit(allocator);
    try empty.replace(allocator, .{ .availability = .current, .revision = 1 });
    try expectObservationOwnedCapacitiesExact(&empty);

    const one = [_]u8{'x'};
    var one_process = pty.types.ForegroundProcessName{ .pid = 100, .len = 1 };
    one_process.bytes[0] = 'p';
    var one_observation: RuntimeObservation = .{};
    defer one_observation.deinit(allocator);
    try one_observation.replace(allocator, .{
        .cwd = &one,
        .cwd_host = &one,
        .window_title = &one,
        .ssh_remote_dest = &one,
        .clipboard_read_target = &one,
        .foreground_processes = &.{one_process},
        .agent_progress = &one,
    });
    try expectObservationOwnedCapacitiesExact(&one_observation);

    const near_cap_len = host_protocol.max_control_json - 3;
    try std.testing.expect(near_cap_len < host_protocol.max_control_json);
    try std.testing.expect(near_cap_len + 4 > host_protocol.max_control_json);
    const bytes = try allocator.alloc(u8, near_cap_len);
    defer allocator.free(bytes);
    @memset(bytes, 'x');
    var process = pty.types.ForegroundProcessName{ .pid = 101, .len = 1 };
    process.bytes[0] = 'p';

    var observation: RuntimeObservation = .{};
    defer observation.deinit(allocator);
    try observation.replace(allocator, .{
        .availability = .current,
        .revision = 2,
        .cwd = bytes,
        .cwd_host = bytes,
        .window_title = bytes,
        .ssh_remote_dest = bytes,
        .clipboard_read_target = bytes,
        .foreground_processes = &.{process},
        .agent_progress = bytes,
    });
    try expectObservationOwnedCapacitiesExact(&observation);
}

fn expectObservationOwnedCapacitiesExact(observation: *const RuntimeObservation) !void {
    try std.testing.expectEqual(observation.cwd.items.len, observation.cwd.capacity);
    try std.testing.expectEqual(observation.cwd_host.items.len, observation.cwd_host.capacity);
    try std.testing.expectEqual(observation.window_title.items.len, observation.window_title.capacity);
    try std.testing.expectEqual(observation.ssh_remote_dest.items.len, observation.ssh_remote_dest.capacity);
    try std.testing.expectEqual(observation.clipboard_read_target.items.len, observation.clipboard_read_target.capacity);
    try std.testing.expectEqual(observation.foreground_processes.items.len, observation.foreground_processes.capacity);
    try std.testing.expectEqual(observation.agent_progress.items.len, observation.agent_progress.capacity);
}

// view()가 관측 스칼라를 하나라도 빠뜨리면 그 기능이 제품에서 조용히 무동작한다 — 실제로 mouse_tracking_mode·
// bell_count·clipboard_* 가 그렇게 죽어 있었고(캐시엔 값이 있는데 view가 안 실어 term 캐시는 기본값), 테스트가
// term.rt.observation.*를 직접 대입하는 바람에 CI도 통과했다. 이제 view()는 이름·타입이 같은 필드를 자동 복사하므로
// 이 테스트는 그 자동 복사가 실제로 **모든** 스칼라를 덮는지(그리고 표현이 다른 필드는 수동으로 채워지는지) 고정한다.
test "RuntimeObservation.view: 모든 관측 필드가 view로 전달된다(자동 복사 커버리지)" {
    const allocator = std.testing.allocator;
    var obs: RuntimeObservation = .{};
    defer obs.deinit(allocator);

    // 스칼라를 전부 기본값과 다른 값으로 채운다 — 하나라도 view가 안 실으면 아래 단언이 깨진다.
    obs.availability = .current;
    obs.revision = 7;
    obs.observer_generation = 9;
    obs.title_generation = 11;
    obs.size = .{ .cols = 120, .rows = 40 };
    obs.semantic_state = .command;
    obs.alt_active = true;
    obs.app_cursor_keys = true;
    obs.app_keypad = true;
    obs.kitty_flags = 5;
    obs.alternate_scroll = false;
    obs.mouse_tracking = true;
    obs.mouse_tracking_mode = 4;
    obs.bracketed_paste = true;
    obs.bell_count = 3;
    obs.clipboard_write_seq = 13;
    obs.clipboard_read_seq = 17;
    obs.foreground_available = true;
    obs.foreground_pgid = 55;
    try obs.cwd.appendSlice(allocator, "/repo");
    try obs.cwd_host.appendSlice(allocator, "box"); // cwd와 한 쌍 — view가 안 실으면 원격 판정이 통째로 죽는다
    try obs.window_title.appendSlice(allocator, "work");
    try obs.clipboard_read_target.appendSlice(allocator, "p");
    try obs.agent_progress.appendSlice(allocator, "working");

    const v = obs.view();
    // comptime 전수: View의 모든 필드가 기본값과 달라야 한다(= view가 실제로 채웠다). 표현이 다른 필드도 위에서
    // 값을 넣었으므로 같은 규칙으로 검사된다. 새 필드를 추가하고 값을 안 채우면 여기서 실패해 누락을 알린다.
    const defaults: RuntimeObservationView = .{};
    inline for (@typeInfo(RuntimeObservationView).@"struct".fields) |field| {
        if (field.type == []const u8) {
            try std.testing.expect(@field(v, field.name).len > 0);
        } else if (field.type == ?[]const u8 or field.type == []const pty.types.ForegroundProcessName) {
            // optional/slice 표현은 값 유무만 본다(위에서 ssh_remote_dest·processes는 비워 두는 게 정상 상태).
        } else if (@typeInfo(field.type) == .optional) {
            // optional은 표현이 갈려(ssh_remote_dest는 미설정이 정상) 값 유무를 강제하지 않는다.
        } else if (@typeInfo(field.type) == .bool or @typeInfo(field.type) == .int or @typeInfo(field.type) == .@"enum") {
            try std.testing.expect(!std.meta.eql(@field(v, field.name), @field(defaults, field.name)));
        }
    }
    // 대표 값 몇 개는 그대로 실렸는지 직접 확인(자동 복사가 엉뚱한 필드를 덮지 않았는지).
    try std.testing.expectEqual(@as(u8, 4), v.mouse_tracking_mode);
    try std.testing.expectEqual(@as(u64, 3), v.bell_count);
    try std.testing.expectEqual(@as(u64, 13), v.clipboard_write_seq);
    try std.testing.expectEqual(@as(u64, 17), v.clipboard_read_seq);
    try std.testing.expectEqualStrings("p", v.clipboard_read_target);
    try std.testing.expectEqualStrings("/repo", v.cwd);
}
