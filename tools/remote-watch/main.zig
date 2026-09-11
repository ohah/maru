//! **원격 감시자**(RW1 — [계획](../../docs/plans/remote-watch.md)). 원격에서 저장소가 바뀌면
//! stdout 에 `change` 한 줄을 낸다. 그 줄을 받은 maru 가 **자기 읽기 파이프라인을 다시 건다** —
//! 이 프로그램은 git 을 돌리지도, 무엇이 바뀌었는지 말하지도 않는다(계약 §2 「트리거만 바꾼다」).
//!
//! ## 왜 셸이 아니라 바이너리인가
//!
//! 감시 API 는 셸에서 못 부른다 — FSEvents 는 C 호출, inotify·kqueue 는 syscall 이고, 그 CLI 래퍼
//! (`inotifywait`·`fswatch`)는 **기본 설치가 아니다**(계획 §3 실측). 셸로 가면 폴링이 천장이다.
//!
//! ## 고아를 남기지 않는다 — 이 파일의 가장 중요한 계약
//!
//! 감시자는 **설계상 조용하다**(바뀔 때만 출력). 그래서 「쓸 때 EPIPE 로 죽는다」에 기댈 수 없고,
//! 실측에서 **조용한 프로세스는 ssh 채널이 끊겨도 살아남았다**(계획 §5). 남의 서버에 무한 루프를
//! 쌓는 것이 이 트랙의 최악 실패이므로, **stdin 을 감시 대기와 같은 자리에 넣고 EOF 면 종료한다.**
//!
//! ⚠️ 그래서 호출자는 **채널의 stdin 을 열어 둬야 한다.** 닫힌 채로 띄우면 뜨자마자 죽는다.
//!
//! ## 「`std` 만 임포트한다」를 **활동 축에서만** 깬다
//!
//! 목록·변경 wire 는 인코더의 **사본**을 손으로 든다(아래 `rfls_header` 계열) — 크기와 자기완결
//! 때문이고, 드리프트는 실물 왕복 게이트가 막는다. **활동 축(RAV2)은 그럴 수 없다.**
//! 스캐너(`agent_image_index`)는 2,800 줄에 판정자 163 개이고, 계약의 벗기기 규칙(Codex `exec` 의
//! JavaScript 껍데기, 옛 형식 JSON 두 겹, chunk 봉투)이 전부 그 안에 있다. 사본을 들면 **원격과
//! 로컬이 다른 것을 보여 준다** — 이 뷰에서 그것이 최악의 실패다.
//!
//! 그래서 활동 축은 `remote_activity_wire` 모듈 하나를 문다(그것이 스캐너·라벨을 함께 끌어온다).
//! 비용은 쟀다: **+19,072 B(+8.6%)** — 계획 [원격 에이전트 활동 뷰](../../docs/plans/remote-agent-activity.md) §2.3.
//! 방향은 한 쪽이다 — 헬퍼가 세션 모듈을 물고, 그 반대는 없다.

const std = @import("std");
const activity_wire = @import("remote_activity_wire");
const builtin = @import("builtin");

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// 한도 초과로 **일부만 감시하게 된** 경우의 종료 코드. 호출자는 이 값을 보고 폴링으로 내려간다
/// (계획 §RW5) — 반쪽만 감시하면서 최신인 척하는 것이 최악이라 **조용히 계속하지 않는다.**
/// `--version` 이 내는 줄. 설치 쪽이 **이 문자열로** 「우리 것이고 이 판이다」를 확인한다 —
/// 판이 바뀌면 여기를 올리고, 그러면 옛 판이 깔린 원격은 다음 설치에서 갈린다.
///
/// 판 3: `list` 서브커맨드(RF2 — 원격 파일 트리 목록). 판을 올리는 이유가 정확히 이것이다 —
/// GUI 가 `list` 를 보내려면 원격 바이너리에 그것이 **있어야** 하고, 판이 그 사실을 보증한다.
///
/// 판 9: `activity` 서브커맨드(RAV2 — 원격 에이전트 활동). 같은 이유다.
///
/// 판 10: `read` 서브커맨드(RAV5 — 펼침·이미지가 읽을 **구간**). 활동 wire 는 자리만 싣고 바이트는
/// 안 싣는다(계약 §2.4) — 그 바이트를 요청형으로 당겨오는 문이다.
pub const version_line = "maru-remote-watch 10\n";

/// **판 2 부터는 내지 않는다**(RW7d — 한도에서 폴링으로 내려간다). 상수를 남겨 두는 이유는 원격에
/// 아직 **판 1 바이너리가 도는 경우**가 있어서다 — 그쪽은 여전히 이 코드로 나가고, 앱은 그것을
/// 「영구 실패」로 읽어야 한다(판이 갈리면 다음 설치에서 바뀐다).
pub const exit_watch_limit: u8 = 2;
/// 감시 API 자체를 못 열었다(플랫폼 미지원 등). 호출자는 설치를 실패로 보고 현행 동작을 유지한다.
pub const exit_unsupported: u8 = 3;

/// 한 번에 등록할 디렉터리 상한. **넘으면 폴링으로 내려간다**(RW7d) — 넘는 순간 이 프로그램이 아는
/// 것은 「전부는 못 본다」뿐이고, 반쪽을 최신인 척 보여 주는 것이 최악이기 때문이다(계획 §6).
/// 예전에는 여기서 `exit_watch_limit` 으로 나갔고 앱이 포기했다(RW5). 이제 폴링이 있으니 **잃는 것은
/// 지연뿐**이라 포기할 이유가 없다.
const max_dirs: usize = 65_536;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const root = args.next() orelse exitUnsupportedWhy("no root argument");

    // **멱등 확인용 진입점.** 설치 쪽은 「이미 있고 **돌아가는가**」를 물어야 한다 — 파일 존재만 보면
    // 아키텍처가 틀린 바이너리나 잘린 파일을 「설치됨」으로 읽는다(그러면 감시가 조용히 안 된다).
    // 실제로 실행해 보는 것이 그 둘을 함께 가른다.
    if (std.mem.eql(u8, root, "--version")) {
        _ = std.posix.system.write(1, version_line.ptr, version_line.len);
        return;
    }

    // **목록 모드**(RF2 — [계획](../../docs/plans/remote-file-tree.md) §2.2·§10). 디렉터리 하나를
    // 나열해 `maru-rfls 1` wire 로 stdout 에 내고 끝난다 — 감시와 달리 **한 번 답하고 죽는** 모드라
    // stdin 고아 방지 규율이 필요 없다. wire 의 단일 출처는 `src/session/remote_file_listing.zig` 이고,
    // 여기는 그 인코더를 **모듈로 못 물어**(이 바이너리는 std 만 임포트한다 — 크기·자기완결) 손으로
    // 낸다. 드리프트는 빌드가 이 바이너리를 실제로 돌려 그 파서로 되읽는 게이트가 막는다
    // (`test-remote-file-listing` — RW 의 version_line 문자열 대조보다 강한, 바이트 수준 왕복이다).
    if (std.mem.eql(u8, root, "list")) {
        const dir_path = args.next() orelse return exitWith(exit_unsupported);
        return runList(io, dir_path);
    }

    // **활동 모드**(RAV2 — [계획](../../docs/plans/remote-agent-activity.md) §5). 트랜스크립트 하나를
    // 훑어 `maru-rav 1` wire 를 stdout 에 내고 끝난다 — `list` 와 같이 **한 번 답하고 죽는** 모드다.
    //
    // 목록 wire 와 달리 인코더를 **손으로 안 든다** — 위 머리말이 적은 대로 모듈을 문다.
    if (std.mem.eql(u8, root, "activity")) {
        const file_path = args.next() orelse return exitWith(exit_unsupported);
        return runActivity(io, init.gpa, file_path);
    }

    // **구간 읽기 모드**(RAV5). `activity` 가 준 자리로 그 바이트만 돌려준다 — 펼침(계약 §2.4)과
    // 이미지(RAV6)가 쓴다. `list`·`activity` 와 같이 한 번 답하고 죽는다.
    if (std.mem.eql(u8, root, "read")) {
        const file_path = args.next() orelse return exitWith(exit_unsupported);
        const off_text = args.next() orelse return exitWith(exit_unsupported);
        const len_text = args.next() orelse return exitWith(exit_unsupported);
        return runRead(io, init.gpa, file_path, off_text, len_text);
    }

    // **이름 변경 모드**(RF6a — [계획](../../docs/plans/remote-file-tree.md) §2.3 ⑶). 인자는
    // `mv <부모 절대경로> <이전 이름> <새 이름> <dev> <ino>` 다. 계약의 핵심은 **저쪽 한 프로세스
    // 안에서 stat → 비교 → 실행**이라는 것이다 — 셸로 쪼개면(`[ "$(stat …)" = N ] && mv`) 그 사이가
    // 그대로 TOCTOU 창이고, 우리가 보던 파일이 아닌 것을 옮기게 된다.
    //
    // 신원은 **부모를 열어 그 핸들 아래에서** 다시 잰다(경로 재해석 없음 — 로컬의 `openPinnedParent`
    // 가 하는 것과 같은 축). 그리고 rename 은 **비대체**여야 한다 — 대체면 남의 파일이 조용히
    // 사라진다. 못 하는 원격에서는 대체로 내려가지 않고 `unsupported` 로 말한다(fail-closed).
    if (std.mem.eql(u8, root, "mv")) {
        const parent = args.next() orelse return exitWith(exit_unsupported);
        const old_name = args.next() orelse return exitWith(exit_unsupported);
        const new_name = args.next() orelse return exitWith(exit_unsupported);
        const dev_text = args.next() orelse return exitWith(exit_unsupported);
        const ino_text = args.next() orelse return exitWith(exit_unsupported);
        return runRename(io, init.gpa, parent, old_name, new_name, dev_text, ino_text);
    }

    // **삭제 모드**(RF6c — 열린 질문 ④ = ㉰, 사용자 결정 2026-09-06). 인자는
    // `rm <부모 절대경로> <이름> <dev> <ino>` 다. 계약은 `mv` 와 **같은 축**이다 — 저쪽 한 프로세스
    // 안에서 stat → 신원 비교 → `unlinkat`. 셸 `rm` 은 그 보장이 없다(그 사이에 다른 것이 들어오면
    // 엉뚱한 것을 지운다).
    //
    // ⚠️ **되돌리기가 없다.** 원격에는 휴지통이 없고 우리가 만들지도 않는다(§4 ④ — `EXDEV` 와 정리
    // 정책 때문). 그래서 이 모드의 안전은 「되돌릴 수 있다」가 아니라 **「엉뚱한 것을 안 지운다」**
    // 에서 온다. 되돌릴 수 없다는 사실은 **확인 모달이 말한다**(§2.3 ⑷ — 차이를 숨기지 않는다).
    if (std.mem.eql(u8, root, "rm")) {
        const parent = args.next() orelse return exitWith(exit_unsupported);
        const name = args.next() orelse return exitWith(exit_unsupported);
        const dev_text = args.next() orelse return exitWith(exit_unsupported);
        const ino_text = args.next() orelse return exitWith(exit_unsupported);
        return runDelete(io, init.gpa, parent, name, dev_text, ino_text);
    }

    // **만들기 모드**(RF6d). 인자는 `mk <부모 절대경로> <이름> <d|f> <dev> <ino>` 다. `mv`·`rm` 과
    // **같은 축**이다 — 부모를 열어 그 신원을 다시 재고, **배타 생성**으로 만든다
    // (`O_CREAT|O_EXCL` / `mkdirat`). 배타가 계약인 이유는 이름 변경과 같다: 덮어쓰면 남의 파일이
    // 조용히 사라진다. 미리 「있나」를 물으면 그 사이가 창이라, 커널이 판정하게 둔다.
    if (std.mem.eql(u8, root, "mk")) {
        const parent = args.next() orelse return exitWith(exit_unsupported);
        const name = args.next() orelse return exitWith(exit_unsupported);
        const kind = args.next() orelse return exitWith(exit_unsupported);
        const dev_text = args.next() orelse return exitWith(exit_unsupported);
        const ino_text = args.next() orelse return exitWith(exit_unsupported);
        return runCreate(io, init.gpa, parent, name, kind, dev_text, ino_text);
    }

    // 루트 뒤에 오는 것은 **굳히기까지 끝난 git 앞머리**다(RW7b — `ssh_upload.spawnRemoteWatch` 가
    // `git_command.config_overrides` 를 그대로 실어 보낸다). 없으면 폴링을 못 한다.
    var git_prefix: std.ArrayList([]const u8) = .empty;
    defer git_prefix.deinit(init.gpa);
    while (args.next()) |a| try git_prefix.append(init.gpa, a);

    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (dirs.items) |d| init.gpa.free(d);
        dirs.deinit(init.gpa);
    }
    // ⚠️ **실패를 삼키지 않는다**(적대적 검증 2026-09-04 15 회차). `collect` 는 못 여는 디렉터리를
    // 건너뛰는 것과 별개로 OOM 이면 **도중에** 멈춘다 — 그때 `catch {}` 로 넘어가면 남은 절반을 「전부」
    // 로 알고 무장해, §6 이 「최악」이라 못 박은 조용한 반쪽 감시가 된다. 못 하면 못 한다고 말한다.
    collect(io, init.gpa, root, &dirs) catch exitUnsupportedWhy("collect failed (out of memory)");
    // **0 개는 「볼 것이 없다」가 아니라 「못 봤다」다** — 루트를 못 열었다는 뜻이라 폴백해야 한다.
    if (dirs.items.len == 0) exitUnsupportedWhy("root directory could not be opened");
    // ⚠️ **「닿았다」로 묻는다 — 「넘었다」로 물으면 영원히 거짓이다**(적대적 검증 2026-09-04 12 회차).
    // `collect` 는 `>= max_dirs` 에서 «멈추므로» 이 값은 `max_dirs` 를 절대 넘지 않는다. 앞 판은 `>` 로
    // 물어서 이 보고가 **죽은 코드**였고, 그래서 상한을 넘는 저장소가 §6 이 「최악」이라 못 박은 상태 —
    // **조용히 반쪽만 감시** — 로 들어갔다. 판정자는 문자열만 봐서 그것을 못 봤다.
    // **한도를 넘으면 폴링이다**(RW7d) — 나가지 않는다. 폴링도 못 하면 그때 말한다.
    const over_limit = dirs.items.len >= max_dirs;

    switch (builtin.os.tag) {
        .linux => if (over_limit)
            try watchPoll(init.gpa, root, git_prefix.items)
        else
            try watchLinux(io, init.gpa, root, git_prefix.items, &dirs),
        // **폴링이다**(RW7c). kqueue 는 파일 «편집» 을 안 알리고 디렉터리마다 fd 를 써서 한도에도
        // 걸린다(§8.6 ①). 그래서 이 갈래는 저쪽에서 git 을 돌려 다이제스트를 비교한다.
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => try watchPoll(init.gpa, root, git_prefix.items),
        else => exitUnsupportedWhy("this operating system has no watch backend"),
    }
}

fn exitWith(code: u8) noreturn {
    std.process.exit(code);
}

/// **`exit=3` 이 왜 났는지 남긴다.** 이 바이너리의 stderr 는 ssh 를 타고 GUI 의 `app.log` 로 간다
/// (`spawnRemoteWatch` 는 자식의 fd 2 를 갈아끼우지 않는다 — 부모 것을 그대로 물려준다).
///
/// 왜 필요한가: `exit_unsupported` 는 **서로 완전히 다른 실패들**을 한 코드로 뭉갠다 — 루트 인자 없음
/// / 수집 실패 / 루트를 못 엶 / 감시 API 못 엶 / git 앞머리 없음 / 첫 다이제스트 실패 / OS 미지원.
/// 앱은 그중 무엇이든 `isPermanent` 로 읽어 **영구 포기**(`.gave_up` — 흡수 상태라 폴더를 접었다 펴도
/// 안 풀린다)로 가는데, 화면에는 「이 원격은 변경을 감시하지 못합니다」 한 줄만 뜬다.
///
/// 2026-09-07 실측: 같은 저장소·같은 인자로 어떤 때는 15 초 넘게 정상 감시하고 어떤 때는 즉시 3 으로
/// 나갔다. 가설 넷(저장소 아님 · git 앞머리 토큰 · 30 초 마감 · 디렉터리 상한)을 세워 **넷 다 실측에
/// 반증**됐고, 그 사이 좁힐 수단이 하나도 없었다 — stderr 에 한 글자도 없기 때문이다.
fn exitUnsupportedWhy(why: []const u8) noreturn {
    const sys = std.posix.system;
    const head = "maru-remote-watch: unsupported - ";
    _ = sys.write(2, head.ptr, head.len);
    _ = sys.write(2, why.ptr, why.len);
    _ = sys.write(2, "\n", 1);
    exitWith(exit_unsupported);
}

// ── 목록 모드(RF2) ──────────────────────────────────────────────────────────────────────────────

/// wire 상수 — `src/session/remote_file_listing.zig` 와 **바이트까지 같아야 한다.** 이 바이너리는
/// std 만 임포트하므로(크기·자기완결) 여기 사본이 있고, 드리프트는 실행형 왕복 게이트가 막는다.
const rfls_header = "maru-rfls 1\n";
const rfmv_header = "maru-rfmv 1\n";

/// 변경 결말 — `src/session/remote_file_mutation.zig` 의 `Outcome` 과 **같은 수**여야 한다.
/// 이 바이너리는 세션 모듈을 못 물어(std 만 임포트) 사본을 든다 — 드리프트는 왕복 게이트가 잡는다.
const MvOutcome = enum(u8) {
    ok = 0,
    stale = 1,
    collision = 2,
    not_found = 3,
    denied = 4,
    invalid = 5,
    io = 6,
    unsupported = 7,
};
const rfls_max_name_bytes: usize = 1024;

/// stdout 에 전부 쓴다. 실패하면 false — 채널이 끊긴 것이고, 부분 레코드를 남기느니 그냥 끝낸다
/// (파서 쪽이 꼬리 부재를 「잘림」으로 읽는다).
fn putAll(bytes: []const u8) bool {
    const sys = std.posix.system;
    var left = bytes.len;
    while (left > 0) {
        const rc = sys.write(1, bytes[bytes.len - left ..].ptr, left);
        const n: isize = @bitCast(rc);
        if (n <= 0) return false;
        left -= @intCast(n);
    }
    return true;
}

/// 신원 stat 의 타깃별 진입점. Zig 0.16 은 이 자리에 **한 이름이 없다** — musl 의 `std.c` 에는
/// `fstat` 계열이 없고([zig-016-syscall-std-gaps]), darwin 은 `std.c` 가 그 자리다. 리눅스는 raw
/// syscall 로 간다(libc 불요·musl 정적과도 무관).
const RawStat = struct { dev: u64, ino: u64, mode: u32 };

fn rawFstat(fd: std.posix.fd_t) ?RawStat {
    return switch (builtin.os.tag) {
        // 자기 자신은 `AT.EMPTY_PATH` 로 묻는다 — fd 하나가 곧 대상이다.
        .linux => linuxStatx(fd, "", std.posix.AT.EMPTY_PATH),
        else => blk: {
            var st: std.c.Stat = undefined;
            if (std.c.fstat(fd, &st) != 0) break :blk null;
            break :blk .{ .dev = @as(u64, @bitCast(@as(i64, st.dev))), .ino = @intCast(st.ino), .mode = @intCast(st.mode) };
        },
    };
}

fn rawFstatAt(dir_fd: std.posix.fd_t, name_z: [*:0]const u8, flags: u32) ?RawStat {
    return switch (builtin.os.tag) {
        .linux => linuxStatx(dir_fd, name_z, flags),
        else => blk: {
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(dir_fd, name_z, &st, @intCast(flags)) != 0) break :blk null;
            break :blk .{ .dev = @as(u64, @bitCast(@as(i64, st.dev))), .ino = @intCast(st.ino), .mode = @intCast(st.mode) };
        },
    };
}

/// 리눅스는 `statx` 하나만 남았다(0.16 — `Stat`/`fstatat` 래퍼가 없다). dev 는 major/minor 로 오므로
/// 한 u64 로 접는다 — wire 계약은 「같은 기계 안에서 같으면 같다」뿐이라 접는 방식은 자유다(§2.3 ⑴).
fn linuxStatx(dir_fd: std.posix.fd_t, path_z: [*:0]const u8, flags: u32) ?RawStat {
    var stx: std.os.linux.Statx = undefined;
    const want: std.os.linux.STATX = .{ .TYPE = true, .MODE = true, .INO = true };
    const rc = std.os.linux.statx(dir_fd, path_z, flags, want, &stx);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    if (!stx.mask.TYPE or !stx.mask.INO) return null; // 커널·FS 가 못 채우면 「모른다」다
    const dev = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
    return .{ .dev = dev, .ino = stx.ino, .mode = @as(u32, stx.mode) };
}

fn putRemoteError(msg: []const u8) void {
    var head: [64]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "! {d} ", .{msg.len}) catch return;
    if (!putAll(h)) return;
    if (!putAll(msg)) return;
    _ = putAll("\n");
}

/// 변경 결말 한 벌을 낸다(`maru-rfmv 1`). 진단은 선택이고 `S` **앞에** 온다 — 파서가 `S` 를 꼬리로
/// 읽으므로 순서가 계약이다.
fn putMvResult(outcome: MvOutcome, message: ?[]const u8) void {
    if (!putAll(rfmv_header)) return;
    if (message) |m| {
        const clipped = if (m.len > 512) m[0..512] else m;
        var head: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "! {d} ", .{clipped.len}) catch return;
        if (!putAll(h)) return;
        if (!putAll(clipped)) return;
        if (!putAll("\n")) return;
    }
    var tail: [16]u8 = undefined;
    const t = std.fmt.bufPrint(&tail, "S {d}\n", .{@intFromEnum(outcome)}) catch return;
    _ = putAll(t);
}

/// 이름이 **이름일 수 있는가**. wire 가 같은 규율을 목록 쪽에서 쓴다(UnsafeName) — 여기서도 막아야
/// `..` 하나가 부모 밖을 가리키는 일이 없다.
fn mvNameIsSafe(name: []const u8) bool {
    if (name.len == 0 or name.len > 1024) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| if (c == '/' or c == 0) return false;
    return true;
}

/// 부모 아래에서 `old` 를 `new` 로 바꾼다 — **신원을 다시 재고, 비대체로**(§2.3 ⑶).
fn runRename(
    io: std.Io,
    gpa: std.mem.Allocator,
    parent: []const u8,
    old_name: []const u8,
    new_name: []const u8,
    dev_text: []const u8,
    ino_text: []const u8,
) void {
    if (parent.len == 0 or parent[0] != '/') return putMvResult(.invalid, "parent is not absolute");
    if (!mvNameIsSafe(old_name) or !mvNameIsSafe(new_name)) return putMvResult(.invalid, "unsafe name");
    if (std.mem.eql(u8, old_name, new_name)) return putMvResult(.invalid, "name unchanged");
    const want_dev = std.fmt.parseInt(u64, dev_text, 10) catch return putMvResult(.invalid, "bad identity");
    const want_ino = std.fmt.parseInt(u64, ino_text, 10) catch return putMvResult(.invalid, "bad identity");

    // 부모를 **열어서** 그 핸들 아래에서만 판단한다 — 경로를 다시 해석하지 않는다.
    var dir = std.Io.Dir.cwd().openDir(io, parent, .{}) catch |err| {
        return putMvResult(mvOutcomeForOpen(err), "opendir failed");
    };
    defer dir.close(io);

    const old_z = gpa.dupeZ(u8, old_name) catch return putMvResult(.io, "out of memory");
    defer gpa.free(old_z);
    const new_z = gpa.dupeZ(u8, new_name) catch return putMvResult(.io, "out of memory");
    defer gpa.free(new_z);

    // 신원 재확인. 링크는 **링크 자신**을 본다(로컬의 `identityAt` 과 같은 축 — `SYMLINK_NOFOLLOW`).
    const st = rawFstatAt(dir.handle, old_z.ptr, std.posix.AT.SYMLINK_NOFOLLOW) orelse
        return putMvResult(.not_found, "source is gone");
    if (st.dev != want_dev or st.ino != want_ino) return putMvResult(.stale, "identity changed");

    switch (renameNoReplace(dir.handle, old_z.ptr, new_z.ptr)) {
        .ok => putMvResult(.ok, null),
        .exists => putMvResult(.collision, "target exists"),
        .denied => putMvResult(.denied, "permission denied"),
        .not_found => putMvResult(.not_found, "source is gone"),
        .unsupported => putMvResult(.unsupported, "this remote cannot rename without replacing"),
        .io => putMvResult(.io, "rename failed"),
    }
}

/// 부모 아래에 `name` 을 만든다 — **부모 신원을 다시 재고**(§2.3 ⑶), **배타로**.
fn runCreate(
    io: std.Io,
    gpa: std.mem.Allocator,
    parent: []const u8,
    name: []const u8,
    kind: []const u8,
    dev_text: []const u8,
    ino_text: []const u8,
) void {
    if (parent.len == 0 or parent[0] != '/') return putMvResult(.invalid, "parent is not absolute");
    if (!mvNameIsSafe(name)) return putMvResult(.invalid, "unsafe name");
    const want_dir = if (std.mem.eql(u8, kind, "d")) true else if (std.mem.eql(u8, kind, "f")) false else return putMvResult(.invalid, "bad kind");
    const want_dev = std.fmt.parseInt(u64, dev_text, 10) catch return putMvResult(.invalid, "bad identity");
    const want_ino = std.fmt.parseInt(u64, ino_text, 10) catch return putMvResult(.invalid, "bad identity");

    var dir = std.Io.Dir.cwd().openDir(io, parent, .{}) catch |err| {
        return putMvResult(mvOutcomeForOpen(err), "opendir failed");
    };
    defer dir.close(io);

    // **부모의 신원**을 다시 잰다 — 그 사이 부모가 갈렸으면 엉뚱한 곳에 만든다.
    const parent_stat = rawFstat(dir.handle) orelse return putMvResult(.io, "fstat failed");
    if (parent_stat.dev != want_dev or parent_stat.ino != want_ino)
        return putMvResult(.stale, "parent identity changed");

    const name_z = gpa.dupeZ(u8, name) catch return putMvResult(.io, "out of memory");
    defer gpa.free(name_z);

    if (want_dir) {
        const rc = std.c.mkdirat(dir.handle, name_z.ptr, 0o755);
        if (rc == 0) return putMvResult(.ok, null);
        return putMvResult(switch (std.posix.errno(rc)) {
            .EXIST => .collision,
            .ACCES, .PERM, .ROFS => .denied,
            .NOENT => .not_found,
            else => .io,
        }, "mkdir failed");
    }
    // `O_EXCL` 이 곧 「덮어쓰지 않는다」다 — 미리 물어보면 그 사이가 창이다.
    const fd = std.c.openat(dir.handle, name_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) {
        _ = std.c.close(fd);
        return putMvResult(.ok, null);
    }
    putMvResult(switch (std.posix.errno(fd)) {
        .EXIST => .collision,
        .ACCES, .PERM, .ROFS => .denied,
        .NOENT => .not_found,
        else => .io,
    }, "create failed");
}

const RenameResult = enum { ok, exists, denied, not_found, unsupported, io };

/// **비대체 rename**. 대체(덮어쓰기)로 조용히 내려가지 않는다 — 그러면 사용자가 모르는 사이 남의
/// 파일이 사라진다. 리눅스는 `renameat2(RENAME_NOREPLACE)`, macOS·BSD 는 `renameatx_np(RENAME_EXCL)`
/// 이고, 커널·파일시스템이 그 플래그를 모르면 `unsupported` 로 **말한다**(§2.5 — 조용한 폴백 금지).
fn renameNoReplace(dir_fd: std.posix.fd_t, old_z: [*:0]const u8, new_z: [*:0]const u8) RenameResult {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            const rc = linux.syscall5(
                .renameat2,
                @as(usize, @bitCast(@as(isize, dir_fd))),
                @intFromPtr(old_z),
                @as(usize, @bitCast(@as(isize, dir_fd))),
                @intFromPtr(new_z),
                rename_noreplace,
            );
            return switch (linux.errno(rc)) {
                .SUCCESS => .ok,
                .EXIST, .NOTEMPTY => .exists,
                .ACCES, .PERM, .ROFS => .denied,
                .NOENT => .not_found,
                // 옛 커널(4.0 미만)·플래그를 모르는 파일시스템. **대체로 안 내려간다.**
                .NOSYS, .INVAL, .OPNOTSUPP => .unsupported,
                else => .io,
            };
        },
        else => {
            const rc = renameatx_np(dir_fd, old_z, dir_fd, new_z, rename_excl);
            if (rc == 0) return .ok;
            return switch (std.posix.errno(rc)) {
                .EXIST, .NOTEMPTY => .exists,
                .ACCES, .PERM, .ROFS => .denied,
                .NOENT => .not_found,
                .OPNOTSUPP, .INVAL => .unsupported, // darwin 은 NOTSUP 이 OPNOTSUPP 과 같은 수다
                else => .io,
            };
        },
    }
}

const rename_noreplace: usize = 1; // linux RENAME_NOREPLACE
const rename_excl: c_uint = 0x0000_0004; // macOS RENAME_EXCL

extern "c" fn renameatx_np(fromfd: c_int, from: [*:0]const u8, tofd: c_int, to: [*:0]const u8, flags: c_uint) c_int;

/// 부모 아래에서 `name` 을 지운다 — **신원을 다시 재고**(§2.3 ⑶), 디렉터리면 빈 것만.
///
/// 디렉터리를 재귀로 안 지운다: 한 프로세스 안에서 신원을 재는 보장이 **트리 전체로는 성립하지
/// 않고**(내려가는 동안 아래가 바뀔 수 있다), 되돌리기가 없는 곳에서 재귀 삭제는 사고의 크기가
/// 다르다. 빈 디렉터리만 지우고 나머지는 화면이 말한다.
fn runDelete(
    io: std.Io,
    gpa: std.mem.Allocator,
    parent: []const u8,
    name: []const u8,
    dev_text: []const u8,
    ino_text: []const u8,
) void {
    if (parent.len == 0 or parent[0] != '/') return putMvResult(.invalid, "parent is not absolute");
    if (!mvNameIsSafe(name)) return putMvResult(.invalid, "unsafe name");
    const want_dev = std.fmt.parseInt(u64, dev_text, 10) catch return putMvResult(.invalid, "bad identity");
    const want_ino = std.fmt.parseInt(u64, ino_text, 10) catch return putMvResult(.invalid, "bad identity");

    var dir = std.Io.Dir.cwd().openDir(io, parent, .{}) catch |err| {
        return putMvResult(mvOutcomeForOpen(err), "opendir failed");
    };
    defer dir.close(io);

    const name_z = gpa.dupeZ(u8, name) catch return putMvResult(.io, "out of memory");
    defer gpa.free(name_z);

    const st = rawFstatAt(dir.handle, name_z.ptr, std.posix.AT.SYMLINK_NOFOLLOW) orelse
        return putMvResult(.not_found, "target is gone");
    if (st.dev != want_dev or st.ino != want_ino) return putMvResult(.stale, "identity changed");

    // 디렉터리인가는 **방금 잰 mode** 가 말한다 — 다시 물으면 그 사이가 창이다.
    const is_dir = (st.mode & std.posix.S.IFMT) == std.posix.S.IFDIR;
    switch (unlinkNoFollow(dir.handle, name_z.ptr, is_dir)) {
        .ok => putMvResult(.ok, null),
        .exists => putMvResult(.collision, "directory is not empty"),
        .denied => putMvResult(.denied, "permission denied"),
        .not_found => putMvResult(.not_found, "target is gone"),
        .unsupported => putMvResult(.unsupported, "cannot delete this kind of entry"),
        .io => putMvResult(.io, "delete failed"),
    }
}

/// `unlinkat` — 디렉터리면 `AT_REMOVEDIR`(**빈 것만** 지워진다). 링크는 링크 자신을 지운다.
fn unlinkNoFollow(dir_fd: std.posix.fd_t, name_z: [*:0]const u8, is_dir: bool) RenameResult {
    const flags: u32 = if (is_dir) std.posix.AT.REMOVEDIR else 0;
    const rc = std.c.unlinkat(dir_fd, name_z, @intCast(flags));
    if (rc == 0) return .ok;
    return switch (std.posix.errno(rc)) {
        .NOTEMPTY, .EXIST => .exists,
        .ACCES, .PERM, .ROFS => .denied,
        .NOENT => .not_found,
        .ISDIR, .INVAL => .unsupported,
        else => .io,
    };
}

fn mvOutcomeForOpen(err: anyerror) MvOutcome {
    return switch (err) {
        error.FileNotFound => .not_found,
        error.AccessDenied, error.PermissionDenied => .denied,
        error.NotDir => .invalid,
        else => .io,
    };
}

/// 디렉터리 하나를 wire v1 로 나열한다. **한 왕복에 목록 + 신원**이 계약이다(계획 §2.3 ⑵) —
/// 목록과 `stat` 을 나눠 물으면 그 사이가 창이 된다. 신원 숫자는 이 기계의 `(dev, ino)` 지만 wire
/// 계약은 「같은 기계 안에서 같으면 같다」뿐이다(§2.3 ⑴).
///
/// 실패는 **wire 로 말하고 0 으로 끝난다**(`!` 레코드) — 종료 코드는 전송(ssh) 수준의 실패와
/// 가르는 자리로 남긴다. 조용한 실패는 없다(§2.5).
fn runList(io: std.Io, dir_path: []const u8) void {
    if (!putAll(rfls_header)) return;
    // 절대경로만 — 상대는 로그인 셸의 cwd(홈)에 걸려 **다른 폴더**를 나열한다
    // (`git_command.buildRemoteFileRead` 가 같은 이유로 절대만 받는다).
    if (dir_path.len == 0 or dir_path[0] != '/') {
        putRemoteError("path is not absolute");
        return;
    }
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "opendir failed: {s}", .{@errorName(err)}) catch "opendir failed";
        putRemoteError(msg);
        return;
    };
    defer dir.close(io);

    // 나열한 디렉터리 **자신**의 신원 — 열린 핸들을 `fstat` 한다(경로 재해석 없음).
    const dir_stat = rawFstat(dir.handle) orelse {
        putRemoteError("fstat failed");
        return;
    };
    {
        var head: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "D {d} {d}\n", .{ dir_stat.dev, dir_stat.ino }) catch return;
        if (!putAll(h)) return;
    }

    var count: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch {
        // 순회가 중간에 죽으면 **꼬리를 내지 않는다** — 파서가 「잘림」으로 읽어 반쪽 목록이
        // 완결인 척하지 못하게 한다.
        return;
    }) |entry| {
        // 상한 넘는 이름은 **안 싣고 안 센다**(인코더 계약과 같다 — 잘라 실으면 없는 항목이 된다).
        if (entry.name.len == 0 or entry.name.len > rfls_max_name_bytes) continue;

        var name_z: [rfls_max_name_bytes + 1]u8 = undefined;
        @memcpy(name_z[0..entry.name.len], entry.name);
        name_z[entry.name.len] = 0;
        const name_ptr: [*:0]const u8 = name_z[0..entry.name.len :0];

        // 항목 신원은 `lstat` 축이다(링크 자신) — 종류 판정과 같은 한 번의 stat 에서 나온다.
        const st = rawFstatAt(dir.handle, name_ptr, std.posix.AT.SYMLINK_NOFOLLOW) orelse continue;

        const letter: u8 = if (std.posix.S.ISDIR(st.mode))
            'd'
        else if (std.posix.S.ISLNK(st.mode)) blk: {
            // 링크가 디렉터리를 가리키면 `S`(트리가 펼칠 수 있다), 아니면·끊겼으면 `s`.
            const followed = rawFstatAt(dir.handle, name_ptr, 0) orelse break :blk @as(u8, 's');
            break :blk if (std.posix.S.ISDIR(followed.mode)) @as(u8, 'S') else 's';
        } else if (std.posix.S.ISREG(st.mode))
            'f'
        else
            'o';

        var head: [96]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "E {d} {d} {c} {d} ", .{ st.dev, st.ino, letter, entry.name.len }) catch continue;
        if (!putAll(h)) return;
        if (!putAll(entry.name)) return;
        if (!putAll("\n")) return;
        count += 1;
    }

    var tail: [32]u8 = undefined;
    const t = std.fmt.bufPrint(&tail, "X {d}\n", .{count}) catch return;
    _ = putAll(t);
}

/// 루트 아래 디렉터리를 모은다. **`st_mode` 로 판정한다** — `nftw` 의 `FTW_D` 는 libc 마다 값이 달라
/// (glibc 1 · musl 2) 상수를 박으면 **조용히 아무것도 감시하지 않는다**(실측에서 그렇게 당했다).
/// `std.Io.Dir` 의 항목 종류를 쓰면 그 판정을 libc 가 아니라 std 가 진다.
fn collect(io: std.Io, gpa: std.mem.Allocator, root: []const u8, out: *std.ArrayList([]u8)) !void {
    if (out.items.len >= max_dirs) return;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    try out.append(gpa, try gpa.dupe(u8, root));

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // `.git` 은 **본다**(index·HEAD 가 바뀌는 자리다). 빌드 산출물은 호출자가 정할 일이라
        // 여기서 목록을 박지 않는다 — 박으면 저장소마다 다른 규칙을 이 바이너리가 지게 된다.
        const child = try std.fs.path.join(gpa, &.{ root, entry.name });
        defer gpa.free(child);
        try collect(io, gpa, child, out);
        if (out.items.len >= max_dirs) return;
    }
}

/// 바뀌었다고 한 줄 낸다. **쓰기가 실패하면 종료한다** — 채널이 끊긴 것이고, 계속 돌면 고아가 된다.
fn announce() bool {
    const sys = std.posix.system;
    var left: usize = 7;
    const msg = "change\n";
    while (left > 0) {
        const rc = sys.write(1, msg[7 - left ..].ptr, left);
        const n: isize = @bitCast(rc);
        if (n <= 0) return false;
        left -= @intCast(n);
    }
    return true;
}

/// 리눅스: inotify 인스턴스 **하나**에 디렉터리마다 watch 를 건다(watch 는 fd 가 아니다 — 한도는
/// `max_user_watches` 이지 `ulimit -n` 이 아니다, 계획 §6). 그 fd 와 **stdin 을 함께 `poll`** 한다.
///
/// ⚠️ **디렉터리가 새로 생기면 다시 무장한다**(적대적 검증 2026-09-04 14 회차 — 실측). inotify 는
/// 새 디렉터리를 자동으로 안 본다. 시작할 때 걸어 둔 것만 보므로, 그냥 두면:
///
/// | 동작 | 알림 |
/// |---|---|
/// | 새 디렉터리 생성 | 1 (부모에서 온다) |
/// | **그 안에 파일 생성** | **0** |
/// | **그 안의 파일 수정** | **0** |
///
/// `git checkout` 이 디렉터리를 만드는 브랜치로 옮기거나 새 모듈을 만들면 그 뒤 편집이 통째로 안
/// 보인다 — §6 이 「최악」이라 못 박은 조용한 반쪽 감시다.
fn watchLinux(io: std.Io, gpa: std.mem.Allocator, root: []const u8, git_prefix: []const []const u8, dirs: *std.ArrayList([]u8)) !void {
    const linux = std.os.linux;
    const ifd: i32 = @intCast(linux.inotify_init1(0));
    if (ifd < 0) exitUnsupportedWhy("could not open the inotify instance");
    var fds = [_]std.posix.pollfd{
        .{ .fd = ifd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }, // 채널이 끊기면 여기서 걸린다
    };
    // ⚠️ **한도에 걸리면 폴링으로 내려간다**(RW7d). `max_user_watches` 소진은 저 호스트의 형편이지
    // 「못 한다」가 아니다 — 폴링은 같은 것을 보고 느릴 뿐이다(계획 §11.7).
    armLinux(gpa, ifd, dirs.items) catch |err| switch (err) {
        error.WatchLimit => {
            _ = std.c.close(ifd);
            return watchPoll(gpa, root, git_prefix);
        },
        else => return err,
    };
    var buf: [8192]u8 = undefined;
    while (true) {
        _ = std.posix.poll(&fds, -1) catch return;
        if (fds[1].revents != 0) return; // stdin EOF/HUP → 종료(고아 방지)
        if (fds[0].revents == 0) continue;
        const rc = std.posix.system.read(ifd, &buf, buf.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) return;
        // **이벤트를 세지도, 경로를 읽지도 않는다.** 무엇이 몇 개 바뀌었는지는 호출자가 다시 읽어
        // 알아낸다(계약 §2). 여기서 보는 것은 **비트 하나** — 「디렉터리가 관련됐는가」뿐이고, 그것은
        // 파싱 계약이 아니라 **다시 무장해야 하는가**라는 이 프로세스 안의 질문이다.
        if (sawDirEvent(buf[0..@intCast(n)])) {
            for (dirs.items) |d| gpa.free(d);
            dirs.clearRetainingCapacity();
            collect(io, gpa, root, dirs) catch exitUnsupportedWhy("rescan collect failed (out of memory)");
            if (dirs.items.len == 0) exitUnsupportedWhy("rescan found no directories");
            if (dirs.items.len >= max_dirs) {
                _ = std.c.close(ifd);
                return watchPoll(gpa, root, git_prefix); // 재무장 중에 넘었다 — 같은 이유로 폴링이다
            }
            // 이미 걸린 경로에 다시 걸면 **같은 wd 를 돌려준다** — 그래서 전부 다시 거는 것이 안전하고,
            // 어느 것이 새것인지 알 필요가 없다(그걸 알려면 wd→경로 표를 지어야 한다).
            armLinux(gpa, ifd, dirs.items) catch |err| switch (err) {
                error.WatchLimit => {
                    _ = std.c.close(ifd);
                    return watchPoll(gpa, root, git_prefix);
                },
                else => return err,
            };
        }
        if (!announce()) return;
    }
}

/// 목록의 디렉터리마다 watch 를 건다. **멱등이다** — 같은 경로면 같은 wd 가 온다.
///
/// 한도(`max_user_watches` 소진)는 **나가지 않고 돌려준다** — 호출자가 폴링으로 내려간다(RW7d).
fn armLinux(gpa: std.mem.Allocator, ifd: i32, dirs: []const []u8) error{ OutOfMemory, WatchLimit }!void {
    const linux = std.os.linux;
    const mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
        linux.IN.MOVED_TO | linux.IN.MOVED_FROM | linux.IN.ATTRIB;
    for (dirs) |d| {
        const z = try gpa.dupeZ(u8, d);
        defer gpa.free(z);
        const wd: isize = @bitCast(linux.inotify_add_watch(ifd, z, mask));
        // ENOSPC = `max_user_watches` 소진. **일부만 보고 계속하지 않는다** — 폴링으로 내려간다.
        if (wd < 0) return error.WatchLimit;
    }
}

/// 이 배치에 **디렉터리가 얽힌 이벤트**가 있었나. `struct inotify_event` 는 `{ i32 wd; u32 mask;
/// u32 cookie; u32 len; }` 뒤에 `len` 바이트 이름이 붙는 가변 길이라, 그 머리만 훑는다.
fn sawDirEvent(bytes: []const u8) bool {
    const header = 16;
    const in_isdir: u32 = 0x4000_0000;
    var off: usize = 0;
    while (off + header <= bytes.len) {
        const mask = std.mem.bytesToValue(u32, bytes[off + 4 ..][0..4]);
        const len = std.mem.bytesToValue(u32, bytes[off + 12 ..][0..4]);
        if (mask & in_isdir != 0) return true;
        off += header + len;
    }
    return false;
}

/// 폴링 주기. 짧을수록 화면이 빨라지고 저쪽 부하가 는다 — 5 초에서 한 번이 저쪽 코어의 1% 미만이다
/// (실측: 다이제스트 한 번 0.04 s, 5 만 파일 저장소에서 0.11 s).
const poll_interval_ns: i128 = 5 * std.time.ns_per_s;

/// stdin 을 얼마나 자주 들여다보나. **고아 방지가 1 급 규율**이라(§5) 채널이 끊기면 한 주기가 아니라
/// 이 시간 안에 끝나야 한다.
const poll_tick_ms: c_int = 250;

/// 다이제스트에 넣을 읽기들. **도크가 읽는 것과 같은 범위여야 한다**(§11.3) — `status` 하나만 보면
/// 다른 곳에서 만든 브랜치·워크트리를 못 잡아 inotify 보다 좁아진다. 셋을 합쳐도 0.04 s 다(실측).
/// ⚠️ **`status` 만으로는 「틀린 화면」이 나온다** — 계획 §3 이 이미 재서 적어 둔 것이고, RW7 의 첫
/// 판이 그 경고를 그대로 밟았다(적대적 검증 2026-09-04). 실측: 이미 수정된 파일을 **더** 고치면
/// `status` 바이트는 그대로인데 `diff --numstat` 은 `1 1` → `3 3` 으로 바뀐다 — 그 숫자가 도크 행마다
/// 보이는 `+N −M` 이다. 그래서 다이제스트는 **화면의 숫자를 만드는 읽기까지** 봐야 한다.
///
/// 첫 줄(`status`)은 **필수**다. 나머지는 실패해도 「실패했다」를 해시에 넣고 계속한다 — `origin` 이
/// 없는 저장소에서 `rev-list` 가 실패한다고 감시 전체가 멀면 안 된다.
const digest_reads = [_][]const []const u8{
    &.{ "status", "--porcelain=v2", "--branch", "--untracked-files=all" },
    &.{ "for-each-ref", "--format=%(refname) %(objectname)" },
    &.{ "worktree", "list", "--porcelain" },
    // 행별 `+N −M` — 작업트리와 스테이지 양쪽(§3 이 잰 구멍이 여기다)
    &.{ "diff", "--numstat", "--find-renames", "--no-ext-diff", "--no-textconv" },
    &.{ "diff", "--numstat", "--find-renames", "--no-ext-diff", "--no-textconv", "--cached" },

    // ⚠️ **머리 줄 `↑↓` 는 여기 «없다» — 위 둘이 이미 덮는다**(적대적 검증 2026-09-05 — 실측).
    //
    // 한때 `rev-list --count --left-right origin/HEAD...HEAD` 를 넣었다. §3 이 「fetch 로 `↑↓` 만
    // 바뀌면 status 로는 못 본다」를 재 두었기 때문인데, **그 측정은 `status` 단독 기준이었다.**
    // `for-each-ref` 가 들어온 뒤로는 겹친다: `↑↓` 는 **어느 한쪽 ref 가 움직여야만** 바뀌고, ref 가
    // 움직이면 `for-each-ref` 의 oid 가 바뀐다. 분리 HEAD 처럼 `refs/` 밖인 경우는 `status --branch`
    // 의 `branch.oid` 가 덮는다. 둘 다 실측했다:
    //   비기본 기준(`origin/feat`)만 움직임 → `rev-list` 없이도 다이제스트가 바뀐다
    //   분리 HEAD 를 옮김                   → 마찬가지
    //
    // 그래서 **같은 사실을 두 번 묻던 것**이고, 5 초마다 원격에서 도는 명령 하나를 줄였다.
    // (도크가 숫자를 «그릴» 때는 여전히 클라이언트가 `rev-list` 를 돌린다 — 그쪽은 값이 필요하다.)
};

/// 한 명령의 결과. **`channel_closed` 가 있는 이유**가 이 파일의 1 급 규율이다 — git 이 멈춰 있는
/// 동안에도 채널이 끊기면 «즉시» 끝나야 한다(§5).
const RunResult = enum { ok, failed, channel_closed };

/// git 하나가 멈춰 있을 수 있는 최대 시간. 넘으면 죽이고 「못 읽었다」로 친다.
///
/// ⚠️ **여유를 처음엔 잘못 적었다.** 「큰 저장소의 `status` 도 0.1 s 대」라고 썼는데 그 「큰」이 몇
/// 만이었다. 40 만 파일에서 다시 재니 `status` **1.423 s**(계획 §11.9 ①) — 그래도 이 값의 5 % 라
/// 결론은 같지만, 근거는 열 배 이상 빡빡했다. 콜드 페이지 캐시(`sudo purge` 직후)도 1.558 s 로
/// 거의 같다 — 이 비용은 IO 가 아니라 `stat` 이라 캐시 상태에 안 흔들린다.
///
/// 즉 이 값에 걸릴 일은 **병든 원격이거나 네트워크 파일시스템**이다(후자는 못 쟀다 — §11.9 ③).
/// 걸리면 「잠깐 실패」로 넘어가 다음 주기에 다시 시도한다.
const command_deadline_ms: i64 = 30_000;

/// 한 명령을 돌려 stdout 을 해시에 흘려 넣는다. **출력을 모아 두지 않는다** — 다이제스트만 필요하고,
/// 큰 저장소의 `status` 출력을 통째로 들고 있을 이유가 없다.
///
/// `std.process.Child` 를 안 쓴다 — 이 파일은 이미 raw posix 로 사는데(§5 의 `poll` 결속) 그 API 는
/// 판마다 흔들려 왔다. fork/exec 는 여기서 예순 줄이고 흔들리지 않는다.
///
/// ⚠️ **git 을 기다리는 동안에도 stdin 을 본다**(적대적 검증 2026-09-04 17 회차 — 실측). 앞 판은
/// 파이프를 블로킹으로 읽었는데, git 이 멈추면 그 `read` 에서 서서 **채널이 끊겨도 안 끝났다** —
/// 남의 서버에 고아가 남는다. 이 트랙의 최악 실패다.
/// 마지막 git 실행이 어떻게 끝났는지. **`unsupported` 문구에 실어 보내려고** 둔다 — 자식의 stderr 는
/// `/dev/null` 이라(경고가 다이제스트에 섞이면 안 된다) 실패 사유를 그 밖으로는 알 길이 없다.
///
/// 2026-09-09 실측: 앱이 `first git digest read failed` 로 감시를 접었는데, 그 한 줄로는 「git 이
/// 없다」·「저장소가 아니다」·「시한을 넘겼다」가 구별되지 않았다. 재현해 보니 저장소가 아닌 루트에서
/// git 이 128 로 끝나는 것이었지만, 그 숫자가 로그에 없어 원격에서 손으로 재현하기 전까지 몰랐다.
///
/// 단일 스레드 폴링 루프라 전역 한 칸으로 충분하다.
var last_exit: i32 = -1;
var last_signal: i32 = -1;

fn hashCommand(gpa: std.mem.Allocator, argv: []const []const u8, hasher: *std.hash.Wyhash) RunResult {
    var zargs: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (zargs.items) |a| if (a) |ptr| gpa.free(std.mem.span(ptr));
        zargs.deinit(gpa);
    }
    for (argv) |a| {
        const z = gpa.dupeZ(u8, a) catch return .failed;
        zargs.append(gpa, z.ptr) catch {
            gpa.free(z);
            return .failed;
        };
    }
    zargs.append(gpa, null) catch return .failed;

    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return .failed;
    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return .failed;
    }
    if (pid == 0) {
        // **자식의 stdin 은 `/dev/null` 이다.** 우리 stdin 은 ssh 채널이라, git 이 그것을 읽으면
        // 채널 바이트를 먹거나 프롬프트에서 선다(그러면 위 함정으로 되돌아간다).
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 2); // git 의 경고를 다이제스트에 안 섞는다
        }
        _ = std.c.dup2(fds[1], 1);
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        _ = execvp(zargs.items[0].?, @ptrCast(zargs.items.ptr));
        std.c._exit(127);
    }
    _ = std.c.close(fds[1]);

    var wait = [_]std.posix.pollfd{
        .{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }, // 채널 — 여기가 열리면 곧장 접는다
    };
    var buf: [8192]u8 = undefined;
    var left_ms: i64 = command_deadline_ms;
    var outcome: RunResult = .failed;
    while (true) {
        if (left_ms <= 0) break; // 병든 원격 — 죽이고 「못 읽었다」로 친다
        const waited = std.posix.poll(&wait, poll_tick_ms) catch break;
        if (wait[1].revents != 0) {
            outcome = .channel_closed;
            break;
        }
        if (waited == 0) {
            left_ms -= poll_tick_ms;
            continue;
        }
        if (wait[0].revents == 0) continue;
        const rc = std.posix.system.read(fds[0], &buf, buf.len);
        const n: isize = @bitCast(rc);
        if (n < 0) break;
        if (n == 0) {
            outcome = .ok; // EOF — 자식이 출력을 끝냈다
            break;
        }
        hasher.update(buf[0..@intCast(n)]);
    }
    _ = std.c.close(fds[0]);
    if (outcome != .ok) _ = std.c.kill(pid, std.c.SIG.KILL); // 멈춘 자식을 남기지 않는다
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    if (outcome != .ok) return outcome;
    const us: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(us)) {
        last_exit = @intCast(std.c.W.EXITSTATUS(us));
        last_signal = -1;
    } else if (std.c.W.IFSIGNALED(us)) {
        last_exit = -1;
        // `TERMSIG` 는 이 zig 판에서 enum 을 돌려준다 — 정수로 바꿔야 `{d}` 로 찍힌다.
        last_signal = @intCast(@intFromEnum(std.c.W.TERMSIG(us)));
    }
    if (!(std.c.W.IFEXITED(us) and std.c.W.EXITSTATUS(us) == 0)) return .failed;
    return .ok;
}

/// 지금 상태의 다이제스트. 하나라도 못 읽으면 null — 그때는 **바뀌었다고 말하지 않는다**(git 이
/// 잠깐 실패한 것을 변경으로 읽으면 읽기 폭주가 된다).
fn digest(gpa: std.mem.Allocator, root: []const u8, git_prefix: []const []const u8) Digest {
    var hasher = std.hash.Wyhash.init(0);
    for (digest_reads, 0..) |tail, index| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        argv.appendSlice(gpa, git_prefix) catch return .{ .state = .failed };
        argv.appendSlice(gpa, &.{ "-C", root }) catch return .{ .state = .failed };
        argv.appendSlice(gpa, tail) catch return .{ .state = .failed };
        switch (hashCommand(gpa, argv.items, &hasher)) {
            .ok => {},
            // **첫 읽기만 필수다.** git 이 없거나 저장소가 아니면 거기서 드러난다. 나머지는 실패를
            // 해시에 적고 계속한다 — `origin` 이 없는 저장소에서 `rev-list` 가 실패한다고 감시가
            // 통째로 멀면 안 된다(그 저장소가 오히려 흔하다).
            .failed => {
                if (index == 0) return .{ .state = .failed };
                hasher.update("!");
            },
            .channel_closed => return .{ .state = .channel_closed },
        }
        hasher.update("\x00");
    }
    return .{ .state = .ok, .value = hasher.final() };
}

const Digest = struct { state: RunResult, value: u64 = 0 };

/// macOS·BSD·한도 초과에서 쓰는 갈래(RW7). **git 을 돌려 다이제스트를 비교한다** — 파일을 훑지
/// 않는다(전체 stat 걷기는 0.37~0.83 s 로 10 배 넘게 비싸고 `.gitignore` 도 안 따른다).
///
/// ⚠️ 다이제스트는 **이 프로세스 안에서만** 산다. 밖으로 나가는 것은 여전히 `change` 한 줄이라
/// 파싱 계약이 두 벌이 되지 않는다(계약 §2 · §10).
fn watchPoll(gpa: std.mem.Allocator, root: []const u8, git_prefix: []const []const u8) !void {
    if (git_prefix.len == 0) exitUnsupportedWhy("no git prefix - polling needs one"); // 앞머리가 없으면 git 을 못 돌린다
    const first = digest(gpa, root, git_prefix);
    if (first.state == .channel_closed) return;
    if (first.state != .ok) {
        // **왜 실패했는지까지 싣는다.** 자식의 stderr 는 `/dev/null` 이라 이 숫자가 유일한 단서다.
        // git 은 저장소가 아니면 128, 실행 파일을 못 찾으면 우리가 127 로 끝낸다(`execvp` 뒤 `_exit`).
        var buf: [96]u8 = undefined;
        const text = if (last_signal >= 0)
            std.fmt.bufPrint(&buf, "first git digest read failed - killed by signal {d}", .{last_signal})
        else if (last_exit >= 0)
            std.fmt.bufPrint(&buf, "first git digest read failed - git exit {d}", .{last_exit})
        else
            std.fmt.bufPrint(&buf, "first git digest read failed - no child status (spawn or deadline)", .{});
        exitUnsupportedWhy(text catch "first git digest read failed");
    }
    var last = first.value;

    var fds = [_]std.posix.pollfd{
        .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }, // 채널이 끊기면 여기서 걸린다
    };
    var waited_ns: i128 = 0;
    while (true) {
        _ = std.posix.poll(&fds, poll_tick_ms) catch return;
        if (fds[0].revents != 0) return; // stdin EOF/HUP → 종료(고아 방지 — 한 주기를 안 기다린다)
        waited_ns += @as(i128, poll_tick_ms) * std.time.ns_per_ms;
        if (waited_ns < poll_interval_ns) continue;
        waited_ns = 0;
        const now = digest(gpa, root, git_prefix);
        if (now.state == .channel_closed) return; // git 을 기다리는 동안 채널이 끊겼다 — 곧장 끝낸다
        if (now.state != .ok) continue; // 잠깐 실패는 변경이 아니다
        if (now.value == last) continue;
        last = now.value;
        if (!announce()) return;
    }
}

// ── 활동 모드(RAV2) ─────────────────────────────────────────────────────────────────────────────

/// 한 줄 버퍼 — 레코드 하나가 최악 400 B 다(계획 §8 의 계산, 실측 최대 277 B).
///
/// **wire 를 통째로 담지 않는다.** 받는 쪽 상한은 24 MiB 지만 그것은 **읽기를 자르는 값**이지
/// 내는 쪽이 잡아야 할 메모리가 아니다 — 남의 서버에서 24 MiB 를 붙들 이유가 없다. 레코드마다 이
/// 버퍼에 쓰고 곧바로 흘린다.
const activity_line_bytes: usize = 1024;

// **이 버퍼는 못 찬다** — 그 사실을 여기서 못박는다(적대적 J2). `appendRecord` 의 계약은 「버퍼가
// 모자라면 멈춘다(개수에서 빼지 않는다)」인데, 버퍼가 최악을 덮으면 그 경로가 **도달 불가**가 된다.
// 도달 불가가 아니면 판정자가 그것을 못 만들고, 못 만드는 경로는 조용히 썩는다.
comptime {
    if (activity_line_bytes < activity_wire.max_record_bytes) {
        @compileError("remote-watch: activity_line_bytes 가 레코드 최악을 못 덮는다 — 늘리거나, 「버퍼가 차면 멈춘다」 경로를 판정자가 만들 수 있게 하라");
    }
}

/// 스캐너에 먹이는 청크. 제품 스캔 워커와 같은 값이다.
const activity_chunk_bytes: usize = 64 * 1024;

fn runActivity(io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) void {
    var line: [activity_line_bytes]u8 = undefined;

    // 머리말부터 낸다 — 그 뒤에 무엇이 실패하든 받는 쪽은 **판을 확인할 수 있다**.
    const head = activity_wire.appendHeader(&line, 0) orelse return;
    if (!putAll(line[0..head])) return;

    // 절대경로만 — 상대는 로그인 셸의 cwd(홈)에 걸려 **다른 파일**을 연다(`list` 와 같은 규율).
    if (file_path.len == 0 or file_path[0] != '/') {
        putRemoteError("path is not absolute");
        return;
    }

    // **시작할 때 한 번 재서 래치한다**(아래 `channelWatchable` — 그 이유가 거기 있다).
    //
    // ⚠️ **체인 풀기보다 먼저 잰다**(적대적 O2). 뒤에 두면 `resolveChain` 이 도는 동안 래치가 없어
    // 그 구간의 끊김을 영영 못 본다. 실측으로 그 구간은 짧지만(세션 303 개에 1.5 ms) **공백을 남길
    // 이유가 없다**.
    const watch_channel = channelWatchable();

    // **재개/fork 면 부모까지 잇는다**(RAV4 — 계약 §3.3). 저쪽 파일시스템을 훑는 일이라 여기서 한다.
    const chain = resolveChain(io, file_path);
    if (chain.len == 0) {
        putRemoteError("path too long");
        return;
    }

    // **자리를 번호로 싣는다**(계획 §11.3 G1). 못 연 파일이 있어도 뒤가 안 밀린다.
    for (chain.slots[0..chain.len], 0..) |*slot, at| {
        const n = activity_wire.appendFile(&line, 0, @intCast(at), slot.path()) orelse continue;
        if (!putAll(line[0..n])) return;
    }

    var scanner: activity_wire.Scanner = .{};
    defer scanner.deinit(gpa);
    var hits: std.ArrayList(activity_wire.Hit) = .empty;
    defer hits.deinit(gpa);

    const chunk = gpa.alloc(u8, activity_chunk_bytes) catch {
        putRemoteError("out of memory");
        return;
    };
    defer gpa.free(chunk);

    var offset: u64 = 0;
    var truncated = false;
    var opened: [activity_wire.max_chain]?std.Io.File = .{null} ** activity_wire.max_chain;
    defer for (&opened) |*maybe| {
        if (maybe.*) |f| f.close(io);
    };

    // **파일마다 처음부터 다시 센다.** 오프셋은 파일 절대값이고, 어느 파일인지는 `Hit.file_index` 가
    // 든다 — 그 둘을 섞으면 소비자가 엉뚱한 바이트를 읽는다(로컬 스캔 워커와 같은 규율).
    for (chain.slots[0..chain.len], 0..) |*slot, at| {
        const file = std.Io.Dir.cwd().openFile(io, slot.path(), .{
            .mode = .read_only,
            .follow_symlinks = false,
            .allow_directory = false,
        }) catch {
            // **그 파일만 건너뛴다**(부모가 지워졌을 수 있다) — 번호는 그대로다. 머리(자리 0)를
            // 못 열었으면 사유를 남긴다: 그것은 「부분」이 아니라 「못 읽었다」다.
            if (at == 0) {
                putRemoteError("open failed");
                return;
            }
            truncated = true;
            continue;
        };
        opened[at] = file;

        // 파일이 바뀌면 이월 버퍼도 새로 시작해야 한다 — 앞 파일의 잘린 꼬리가 다음 파일 첫 줄에
        // 이어 붙으면 없던 활동이 생긴다.
        scanner.deinit(gpa);
        scanner = .{ .file_index = @intCast(at) };
        scanOne(io, gpa, file, chunk, &scanner, &hits, watch_channel, &offset) catch |err| switch (err) {
            // 🔥 **채널이 끊겼으면 곧바로 접는다 — 다음 파일로 안 간다**(적대적 O2). 여기서 `truncated`
            // 로 뭉개면 M1 의 고침이 체인에서 **깨진다**: 받는 이가 없는데 부모 rollout(실측 최대
            // 1.8 GB)을 계속 훑어 남의 서버 CPU 를 태운다.
            error.ChannelGone => return,
            error.Truncated => truncated = true,
        };
    }

    {
        const at = activity_wire.appendFlags(&line, 0, .{
            // 읽다 멈춘 것도 「다 못 봤다」다 — 제품 스캔 워커가 같은 자리에서 `partial` 을 세운다.
            .partial = scanner.partial or truncated,
            .image_partial = scanner.image_partial,
            .activity_partial = scanner.activity_partial,
            .scanned_bytes = offset,
        }) orelse return;
        if (!putAll(line[0..at])) return;
    }

    // ── 라벨 패스 ───────────────────────────────────────────────────────────────────────────
    // 제품 스캔 워커와 **같은 모양**이다: 파일을 열어 둔 채 positional read 로 그 자리만 읽는다.
    // 라벨을 여기서 만드는 이유는 계약 §2.4 — 저쪽 오프셋을 이쪽이 읽을 수 없기 때문이다.
    var written: u64 = 0;
    for (hits.items) |hit| {
        // **그 자리의 파일에서 읽는다.** 체인이 여럿이면 `file_index` 가 유일한 답이다 — 첫 파일로
        // 고정하면 부모의 활동을 현재 파일에서 읽어 엉뚱한 바이트가 라벨이 된다(RAV4).
        const file = (if (hit.file_index < opened.len) opened[hit.file_index] else null) orelse {
            const at = activity_wire.appendRecord(&line, 0, .{ .hit = hit, .label = .{} }) orelse return;
            if (!putAll(line[0..at])) return;
            written += 1;
            continue;
        };
        var label: activity_wire.Label = .{};
        if (hit.activity != .none and hit.data_len > 0) {
            // 로컬과 같이 **전량**을 읽는다. 앞부분만 읽으면 읽기(`read`) 활동의 basename 이 달라진다.
            if (gpa.alloc(u8, hit.data_len)) |raw| {
                defer gpa.free(raw);
                if (readAllAt(io, file, raw, hit.data_offset)) {
                    label = activity_wire.activityLabel(raw, hit.activity == .read);
                }
            } else |_| {}
        }
        if (hit.time_rel != 0) {
            var tbuf: [activity_wire.time_window_bytes]u8 = undefined;
            const n = file.readPositional(io, &.{&tbuf}, hit.line_offset + hit.time_rel) catch 0;
            if (n > 0) label.time_s = activity_wire.timestampSeconds(tbuf[0..n]);
        }

        // **버퍼가 모자라면 멈춘다 — 개수에서 빼지 않는다**(`appendRecord` 의 계약). 빼면 꼬리
        // count 가 맞아 받는 쪽이 「완결」로 읽고, 못 실은 활동이 조용히 사라진다.
        const at = activity_wire.appendRecord(&line, 0, .{ .hit = hit, .label = label }) orelse return;
        if (!putAll(line[0..at])) return;
        written += 1;
    }

    const at_tail = activity_wire.appendTail(&line, 0, written) orelse return;
    _ = putAll(line[0..at_tail]);
}

/// stdin 이 **지금 무언가를 내놓을 수 있나**(EOF 포함) — 기다리지 않고 본다(timeout 0).
///
/// **`events = POLL.IN` 이어야 한다.** `events = 0` 으로 두면 파이프의 쓰는 쪽이 닫혀도 아무것도 안
/// 걸린다(실측: 4.1 GB 파일에서 조기 종료가 **안 났다**). 감시 모드가 stdin 을 거는 방식이 곧
/// 정답이었다(`.{ .fd = 0, .events = POLL.IN }`) — 그것을 안 보고 새로 지었다가 한 번 틀렸다.
fn stdinSpeaks() bool {
    var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, 0) catch return false;
    if (n == 0) return false;
    // `POLLNVAL` = fd 0 이 아예 없다. 그것도 「말한다」로 센다 — 아래 래치가 그런 호출을 감시 밖으로
    // 돌린다.
    return fds[0].revents != 0;
}

/// 이 호출의 stdin 이 **살아 있는 채널인가** — 시작할 때 **한 번** 재서 래치한다.
///
/// 🔥 **래치가 없으면 정상 호출에서 활동이 통째로 빈다**(적대적 M2 · 실측). 리눅스에서 `/dev/null`
/// 이나 닫힌 fd 0 은 `POLL.IN` 이 **즉시** 서므로(읽으면 EOF) 첫 청크에서 「끊겼다」로 읽힌다 —
/// 실측 3.6 MB 가 나와야 할 자리에 **33 B**(머리말과 `F` 뿐)가 나왔다. 그리고 이 축의 전송
/// (`ssh_upload.runArgvCapped`)은 자식의 **stdin 을 닫는다**(`close(0)`) — 즉 그 조합이 곧 제품 경로다.
///
/// 그래서 가른다: **시작 시점에 이미 말하면 그것은 채널이 아니다**(`/dev/null`·닫힘·리다이렉트).
/// 살아 있는 ssh 채널은 우리가 stdin 을 안 쓰므로 조용하고, 그 조용함이 깨지는 순간이 곧 끊김이다.
fn channelWatchable() bool {
    return !stdinSpeaks();
}

/// 그 자리를 **다 읽었을 때만** 참. 짧게 읽고 라벨을 만들면 잘린 텍스트가 온전한 척 뜬다
/// (제품 스캔 워커의 `readAllAt` 과 같은 규율).
fn readAllAt(io: std.Io, file: std.Io.File, dest: []u8, at: u64) bool {
    var got: usize = 0;
    while (got < dest.len) {
        const n = file.readPositional(io, &.{dest[got..]}, at + got) catch return false;
        if (n == 0) return false;
        got += n;
    }
    return true;
}

/// 파일 하나를 스캐너에 먹인다. **채널이 끊기면 곧바로 접는다**(적대적 M1).
///
/// 🔥 **스캔 구간은 출력이 없다 — 그래서 채널이 끊긴 것을 여기서 봐야 한다.** 이 모드를 `list` 를
/// 따라 「한 번 답하고 죽으니 stdin 규율이 필요 없다」고 적었는데 **틀렸다**: `list` 는 readdir 이라
/// 밀리초지만 활동 스캔은 **초 단위**다(실측 3.82 GB → 6.3 초). 그 사이 받는 쪽이 죽어도 `putAll` 을
/// 안 하므로 EPIPE 가 안 나고, 남의 서버는 아무도 안 받을 일에 CPU 를 계속 태운다.
fn scanOne(
    io: std.Io,
    gpa: std.mem.Allocator,
    file: std.Io.File,
    chunk: []u8,
    scanner: *activity_wire.Scanner,
    hits: *std.ArrayList(activity_wire.Hit),
    watch_channel: bool,
    total: *u64,
) error{ Truncated, ChannelGone }!void {
    var offset: u64 = 0;
    while (true) {
        if (watch_channel and stdinSpeaks()) return error.ChannelGone;
        const n = file.readPositional(io, &.{chunk}, offset) catch return error.Truncated;
        if (n == 0) break;
        offset += n;
        total.* += n;
        scanner.feed(gpa, chunk[0..n], hits) catch return error.Truncated;
    }
}

/// 체인 한 자리 — 경로 사본과 그 길이.
const ChainSlot = struct {
    buf: [activity_wire.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn path(self: *const ChainSlot) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *ChainSlot, value: []const u8) bool {
        if (value.len == 0 or value.len > self.buf.len) return false;
        @memcpy(self.buf[0..value.len], value);
        self.len = value.len;
        return true;
    }
};

const Chain = struct {
    slots: [activity_wire.max_chain]ChainSlot = [_]ChainSlot{.{}} ** activity_wire.max_chain,
    len: usize = 0,

    fn append(self: *Chain, value: []const u8) bool {
        if (self.len >= self.slots.len) return false;
        // **이미 담긴 경로면 안 더한다** — 부모가 자기 자신을 가리키는 기록이 오면 같은 파일을 두 번
        // 훑고 활동이 두 배로 뜬다(로컬 `Chain.append` 와 같은 규율).
        for (self.slots[0..self.len]) |*s| {
            if (std.mem.eql(u8, s.path(), value)) return false;
        }
        if (!self.slots[self.len].set(value)) return false;
        self.len += 1;
        return true;
    }
};

/// 재개/fork 면 **부모까지** 잇는다(RAV4 — 계약 §3.3).
///
/// 로컬 `buildChain` 과 같은 절차다: 파일 머리에서 부모 id 를 읽고, `$HOME/.codex/sessions` 아래를
/// 훑어 그 id 의 rollout 을 찾고, 상한까지 반복한다. **다른 것은 「어느 기계의 파일시스템인가」뿐이다** —
/// 그래서 여기(저쪽)에서 돈다.
///
/// codex 전용이다 — claude 는 `/clear` 가 새 파일을 만들 뿐 이전 대화를 압축해 싣지 않으므로 잃는
/// 것이 없고, 부모를 가리키는 기록도 없다.
fn resolveChain(io: std.Io, head: []const u8) Chain {
    var chain: Chain = .{};
    if (!chain.append(head)) return chain;

    const home_z = std.c.getenv("HOME") orelse return chain;
    const home = std.mem.span(home_z);
    if (home.len == 0) return chain;

    var root_buf: [activity_wire.max_path_bytes]u8 = undefined;
    const root_path = std.fmt.bufPrint(&root_buf, "{s}/.codex/sessions", .{home}) catch return chain;
    // head 가 codex rollout 이 아니면 볼 것이 없다(claude 는 부모 개념이 없다).
    if (!std.mem.startsWith(u8, head, root_path)) return chain;

    var cur_buf: [activity_wire.max_path_bytes]u8 = undefined;
    var cur: []const u8 = head;
    while (chain.len < activity_wire.max_chain) {
        var id_buf: [128]u8 = undefined;
        const parent_id = readCodexParentId(io, cur, &id_buf);
        if (parent_id.len == 0) break;

        var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch break;
        defer root.close(io);

        var rel_buf: [activity_wire.max_path_bytes]u8 = undefined;
        var suffix_buf: [160]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buf, "{s}.jsonl", .{parent_id}) catch break;
        const rel = activity_wire.findCodexByThreadId(io, root, suffix, &rel_buf) orelse break;
        // **`findCodexByThreadId` 는 단순 `endsWith` 다.** 그대로 믿으면 `…-Xparent-id.jsonl` 이
        // `parent-id` 의 것으로 잡힌다 — 찾은 이름을 한 번 더 본다(로컬과 같은 가드).
        const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |at| rel[at + 1 ..] else rel;
        if (!activity_wire.isCodexRolloutOf(base, parent_id)) break;

        var abs_buf: [activity_wire.max_path_bytes]u8 = undefined;
        const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ root_path, rel }) catch break;
        if (!chain.append(abs)) break; // 상한이거나 이미 담긴 경로

        // 다음 바퀴를 위해 방금 담은 경로를 들고 간다(`abs_buf` 는 이 반복에서 죽는다).
        if (abs.len > cur_buf.len) break;
        @memcpy(cur_buf[0..abs.len], abs);
        cur = cur_buf[0..abs.len];
    }
    return chain;
}

/// 그 파일이 밝히는 부모 id. 못 읽으면 빈 값이다.
fn readCodexParentId(io: std.Io, path: []const u8, out: []u8) []const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch return "";
    defer file.close(io);
    var head: [activity_wire.codex_meta_window_bytes]u8 = undefined;
    const n = file.readPositional(io, &.{&head}, 0) catch return "";
    if (n == 0) return "";
    return activity_wire.parseCodexParentId(head[0..n], out);
}

// ── 구간 읽기 모드(RAV5) ────────────────────────────────────────────────────────────────────────

/// 그 파일의 `[offset, offset+len)` 을 돌려준다.
///
/// **길이는 요청보다 짧을 수 있다**(파일 끝) — 그것은 오류가 아니라 사실이고, 받는 쪽은 그 차이로
/// 「그새 잘렸다」를 안다. 못 읽은 것(열기 실패·상한 초과·숫자 아님)은 `!` 로 **사유를 남긴다**.
fn runRead(io: std.Io, gpa: std.mem.Allocator, file_path: []const u8, off_text: []const u8, len_text: []const u8) void {
    var line: [128]u8 = undefined;
    const head = activity_wire.appendRangeHeader(&line, 0) orelse return;
    if (!putAll(line[0..head])) return;

    // 절대경로만 — `activity` 와 같은 규율(상대는 로그인 셸의 cwd 에 걸려 **다른 파일**을 연다).
    if (file_path.len == 0 or file_path[0] != '/') {
        putRangeError("path is not absolute");
        return;
    }

    const offset = parseU64(off_text) orelse {
        putRangeError("offset is not a number");
        return;
    };
    const want = parseU64(len_text) orelse {
        putRangeError("length is not a number");
        return;
    };
    // **상한은 받는 쪽이 읽기를 자르는 값과 같다**(`max_range_bytes`). 넘는 요청은 **거절한다** —
    // 잘라서 주면 받는 쪽이 「파일 끝」과 구분하지 못한다.
    if (want > activity_wire.max_range_bytes) {
        putRangeError("length above limit");
        return;
    }

    const file = std.Io.Dir.cwd().openFile(io, file_path, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch |err| {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "open failed: {s}", .{@errorName(err)}) catch "open failed";
        putRangeError(msg);
        return;
    };
    defer file.close(io);

    const buf = gpa.alloc(u8, @intCast(want)) catch {
        putRangeError("out of memory");
        return;
    };
    defer gpa.free(buf);

    var got: usize = 0;
    while (got < buf.len) {
        const n = file.readPositional(io, &.{buf[got..]}, offset + got) catch {
            putRangeError("read failed");
            return;
        };
        if (n == 0) break; // 파일 끝 — 짧은 답은 오류가 아니다
        got += n;
    }

    // **바이트는 길이 접두로 간다** — 개행·NUL 이 들어도 안 깨진다(`appendRangeBytes`).
    if (!putRangeBytes(buf[0..got])) return;
    const tail = activity_wire.appendRangeTail(&line, 0) orelse return;
    _ = putAll(line[0..tail]);
}

/// 10 진수만 받는다. `std.fmt.parseInt` 는 `+5`·`5_0` 을 받아들여 관대하고, 이 값은 선 위에서 온다
/// (활동 코덱이 같은 이유로 같은 규율을 쓴다 — 적대적 A1).
fn parseU64(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var v: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        v = std.math.mul(u64, v, 10) catch return null;
        v = std.math.add(u64, v, c - '0') catch return null;
    }
    return v;
}

/// `B <len> <바이트>\n` 를 흘린다. **바이트를 버퍼에 담지 않는다** — 최대 4 MiB 이고, 머리와 꼬리만
/// 작은 줄 버퍼로 짓는다(`activity` 의 「wire 를 통째로 안 담는다」와 같은 규율).
fn putRangeBytes(bytes: []const u8) bool {
    var head: [64]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "B {d} ", .{bytes.len}) catch return false;
    if (!putAll(h)) return false;
    if (bytes.len > 0 and !putAll(bytes)) return false;
    return putAll("\n");
}

fn putRangeError(msg: []const u8) void {
    var head: [64]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "! {d} ", .{msg.len}) catch return;
    if (!putAll(h)) return;
    if (!putAll(msg)) return;
    _ = putAll("\n");
}
