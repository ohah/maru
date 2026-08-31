//! Windows 표면 스모크가 공유하는 **그리기 호스트**.
//!
//! 창을 열고 스왑체인·아틀라스·셀 파이프라인을 세우고, `renderer.DrawList` 하나를 받아 화면까지
//! 밀어 넣는 절차는 **무엇을 그리든 똑같다**. 파일 트리든 편집기든 다른 것은 "DrawList 를 어떻게
//! 만드나" 한 토막뿐이다.
//!
//! ## 왜 함수로 빼는가
//!
//! `win32_terminal.zig` 머리말이 이미 규율을 세워 뒀다 — *"렌더 경로는 터미널과 같은 네 단계를
//! 그대로 쓴다. 다른 길을 내면 한쪽만 고쳐지는 순간 조용히 갈린다."* 표면마다 이 340 줄을 복사하면
//! 그 규율이 표면 수만큼 깨진다.
//!
//! **빈말이 아니다.** 이 절차 안에서 이미 결함이 셋 나왔고(docs/windows-platform.md §2m.6) 전부
//! 조용한 종류였다:
//!
//! - `RenderFrame` 이 `draw_list` 를 소유하는데 호출부가 또 해제해 **double free** — 스크린샷을
//!   찍고 프로세스를 죽이는 동안에는 teardown 이 안 돌아 안 보였다.
//! - 아틀라스가 커졌는데 파이프라인 텍스처를 안 따라가면 UV 가 어긋난다.
//! - `.resized` 를 안 받으면 창 크기를 바꾼 뒤 표현이 깨진다(형제 스모크 셋 중 하나만 빠져 있었다).
//!
//! 셋 다 **한 자리에 있으면 한 번 고치면 끝나는** 것들이다.
//!
//! ## 남기지 않은 것
//!
//! 배경 쿼드(선택 띠 등)를 여기서 안 넣는다. **그리는 순서가 곧 z 순서**라 띠를 글리프보다 먼저
//! 넣어야 하는데(§2m.7 실측: 뒤에 넣었더니 그 행 글자를 통째로 덮었다), 무엇을 어떤 순서로 넣을지는
//! 표면이 정할 일이다. 그래서 호스트는 **셀 배열을 받아 그리기만** 하고 채우는 것은 호출자가 한다.

const std = @import("std");

const maru = @import("../../maru.zig");
const dwrite_font = @import("dwrite_font.zig");
const win32_text = @import("win32_text.zig");
const win32_window = @import("win32_window.zig");
const win32_terminal = @import("win32_terminal.zig");
const d3d11_present = @import("d3d11_present.zig");
const d3d11_cells = @import("d3d11_cells.zig");
const chrome = maru.chrome;
const renderer = maru.renderer;

pub const Error = error{HostSetupFailed};

/// 어느 단계에서 섰는지. **오류 하나로 뭉치지 않는다** — 폰트가 없는 것과 데스크톱 힙이 마른 것은
/// 사용자가 할 일이 다르다. 진단 문자열은 각 모듈의 `last_*` 전역이 갖고 있다.
pub const Stage = enum { font, window, present, pipeline };

pub var last_stage: Stage = .font;

/// 선 자리의 **원래 오류**. 단계별로 `catch` 해서 하나로 접기 때문에 그냥 두면 `@errorName` 이
/// 사라진다 — 옮기기 전 스모크는 그것을 함께 찍었고, 진단이 줄면 옮긴 것이 아니라 잃은 것이다.
pub var last_error: anyerror = error.HostSetupFailed;

pub const Options = struct {
    /// 창 제목(UTF-16, NUL 종단). `utf8ToUtf16LeStringLiteral` 로 만든다.
    title: [*:0]const u16,
    width_px: i32 = 900,
    height_px: i32 = 620,
};

/// 표면을 그리는 데 필요한 **호스트 조각들**.
///
/// `draw_host.Host` 를 통째로 받지 않는 이유: 합성된 앱 루프(§2m.31~)는 자기 창·스왑체인·
/// 파이프라인을 직접 들고 있어 `Host` 를 안 쓴다. 그쪽도 같은 표면을 그려야 하므로, **쓰는 것만**
/// 받는다. `Host.surfaceCtx()` 가 스모크 쪽 짝이다.
pub const SurfaceCtx = struct {
    renderer_state: *renderer.RendererState,
    /// 측정 텍스트용 래스터라이저. `registry` 는 여기서 채운다(안 채우면 face 를 못 찾아 글자가
    /// 하나도 안 그려진다 — §2m.27 실측).
    rasterizer: win32_text.NeutralRasterizer,
    pipeline: *d3d11_cells.CellPipeline,
    /// **포인터다** — 아틀라스가 커지면 이 값이 함께 움직여야 다음 프레임의 UV 가 맞는다.
    atlas_w: *u32,
    atlas_h: *u32,
    cell_w: u32,
    cell_h: u32,
    /// 이 표면이 차지하는 사각형의 크기(px). 창 전체가 아니라 **도크 자리**일 수 있다.
    viewport_w: u32,
    viewport_h: u32,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    /// **넷 다 포인터다** — `create` 가 힙에 세워 준다. 그래서 `Host` 를 값으로 옮겨도 안을 가리키는
    /// 것이 없다(옛 주석은 자기 참조를 걱정했는데, 타입을 확인하니 그런 자리가 없었다).
    raster: *dwrite_font.Rasterizer,
    scratch: []u8,
    shaper: win32_text.Shaper,
    rasterizer: win32_text.NeutralRasterizer,
    window: *win32_window.Window,
    present: *d3d11_present.Present,
    renderer_state: maru.renderer.RendererState,
    pipeline: *d3d11_cells.CellPipeline,

    cell_w: u32,
    cell_h: u32,
    /// **파이프라인 텍스처가 지금 몇 픽셀인가.** 아틀라스가 커지면 함께 움직인다 — `cellFromNative`
    /// 가 UV 를 나눌 때 쓰는 값이라 어긋나면 글자가 엉뚱한 자리를 가리킨다.
    atlas_w: u32,
    atlas_h: u32,
    /// **`show()` 직후의 클라이언트 크기.** `grid()` 가 이것을 쓴다 — 호출 시점 크기를 다시 읽으면
    /// 창을 키운 뒤 격자가 달라져 셀과 어긋난다. 표현 루프는 셀을 다시 만들지 않으므로 격자도
    /// 처음 값이어야 한다(§2m.6 이 "창을 키워도 행이 더 보이지 않는다" 로 적어 둔 한계와 짝이다).
    initial: win32_window.ClientSize,

    /// 사용: `var host = try Host.open(...); defer host.close();`
    ///
    /// **`renderer_state` 만 값이다.** 나머지 넷은 `create` 가 힙에 세운 포인터라 `Host` 를 옮겨도
    /// 따라간다. `RendererState` 도 자기 안을 가리키지 않으므로(할당은 전부 allocator 로) 안전하다.
    pub fn open(
        allocator: std.mem.Allocator,
        cfg: anytype,
        opts: Options,
    ) Error!Host {
        last_stage = .font;
        const raster = dwrite_font.Rasterizer.create(allocator, cfg.font.family, cfg.font.fallback, cfg.font.size) catch |err| {
            last_error = err;
            return error.HostSetupFailed;
        };
        errdefer raster.destroy();
        const cell_w = raster.metrics.width_px;
        const cell_h = raster.metrics.height_px;

        const scratch = allocator.alloc(u8, win32_text.NeutralRasterizer.scratchSizeFor(cell_w * 2, cell_h)) catch |err| {
            last_error = err;
            return error.HostSetupFailed;
        };
        errdefer allocator.free(scratch);

        last_stage = .window;
        const window = win32_window.Window.create(allocator, opts.title, @intCast(opts.width_px), @intCast(opts.height_px)) catch |err| {
            last_error = err;
            return error.HostSetupFailed;
        };
        errdefer window.destroy();
        window.show();

        last_stage = .present;
        const initial = window.clientSize() orelse
            win32_window.ClientSize{ .width_px = @intCast(opts.width_px), .height_px = @intCast(opts.height_px) };
        const present = d3d11_present.Present.create(allocator, window.hwnd, initial.width_px, initial.height_px) catch |err| {
            last_error = err;
            return error.HostSetupFailed;
        };
        errdefer present.destroy();

        var renderer_state = maru.renderer.RendererState.init(allocator, .{
            .text = .{
                .font_size_px = maru.renderer.textConfigFromFontSize(cfg.font.size, 1).font_size_px,
                .device_scale = 1,
                .cell_width_px = @intCast(cell_w),
                .glyph_cell_width_px = @intCast(cell_w),
                .cell_height_px = @intCast(cell_h),
            },
        });
        errdefer renderer_state.deinit();

        const atlas_w = renderer_state.atlas.config.atlas_width_px;
        const atlas_h = renderer_state.atlas.config.atlas_height_px;
        last_stage = .pipeline;
        const pipeline = d3d11_cells.CellPipeline.createEmptyAtlas(allocator, present.device, present.context, atlas_w, atlas_h) catch |err| {
            last_error = err;
            return error.HostSetupFailed;
        };

        var host = Host{
            .allocator = allocator,
            .raster = raster,
            .scratch = scratch,
            .shaper = undefined,
            .rasterizer = undefined,
            .window = window,
            .present = present,
            .renderer_state = renderer_state,
            .pipeline = pipeline,
            .cell_w = cell_w,
            .cell_h = cell_h,
            .atlas_w = atlas_w,
            .atlas_h = atlas_h,
            .initial = initial,
        };
        host.shaper = .{ .raster = raster };
        // **래스터라이저에 폰트 크기와 배율을 준다.** measured 크롬 텍스트는 글리프마다 크기가
        // 다르고(`GlyphCacheKey.raster_font_size_milli`), 이 둘이 없으면 그 값을 못 푼다 — 도크
        // 글자가 전부 터미널 크기로 구워진다.
        host.rasterizer = .{ .raster = raster, .scratch = scratch, .font_size_pt = cfg.font.size, .scale_milli = 1000 };
        // 창이 크기 변경을 처리할 때 스왑체인을 찾는 손잡이.
        host.window.present.opaque_handle = @ptrCast(present);
        return host;
    }

    /// **`open` 이 만든 것을 만든 역순으로 돌려준다.**
    pub fn close(self: *Host) void {
        self.pipeline.destroy();
        self.renderer_state.deinit();
        self.present.destroy();
        self.window.destroy();
        self.allocator.free(self.scratch);
        self.raster.destroy();
    }

    /// **처음 크기**에 들어가는 셀 격자. 위 `initial` 의 doc 참조 — 지금 크기를 다시 읽지 않는다.
    pub fn grid(self: *const Host) maru.terminal.Size {
        return win32_window.cellsForClient(self.initial.width_px, self.initial.height_px, self.cell_w, self.cell_h) orelse
            .{ .cols = 80, .rows = 24 };
    }

    pub const Prepared = struct {
        frame: maru.renderer.RenderFrame,
        /// 이번 프레임에 아틀라스로 올린 영역 수. 스모크가 보고에 쓴다.
        region_uploads: usize,
    };

    /// DrawList 하나를 프레임으로 만들고 아틀라스를 최신으로 맞춘다.
    ///
    /// **`draw_list` 의 소유권은 프레임으로 넘어간다** — `Prepared.frame.deinit` 이 그것까지 해제한다.
    /// 호출부에서 `defer draw_list.deinit` 을 또 걸면 double free 다(§2m.6 이 실제로 밟았다).
    /// 여기서 실패하면 아직 프레임이 없으므로 **우리가** 해제하고 오류를 낸다.
    pub fn prepare(self: *Host, allocator: std.mem.Allocator, draw_list: maru.renderer.DrawList) !Prepared {
        var list = draw_list;
        var frame = self.renderer_state.buildFrameFromDrawListWithRasterizer(allocator, list, self.shaper, self.rasterizer) catch |err| {
            list.deinit(allocator);
            return err;
        };
        errdefer frame.deinit(allocator);

        try self.syncAtlas();
        return .{ .frame = frame, .region_uploads = self.uploadAtlasRegions(frame) };
    }

    /// **아틀라스가 커지면 파이프라인 텍스처도 따라가야 한다.** 안 그러면 UV 가 옛 크기 기준이라
    /// 글자가 엉뚱한 자리를 가리킨다.
    ///
    /// `prepare` 밖으로 낸 이유는 **measured 텍스트가 프레임을 다른 길로 만들기 때문**이다
    /// (`buildFrameFromGlyphRunListWithRasterizer` — §2m.27). 그쪽도 이 둘은 똑같이 해야 한다.
    pub fn syncAtlas(self: *Host) !void {
        try syncAtlasTexture(self.pipeline, &self.renderer_state, &self.atlas_w, &self.atlas_h);
    }

    /// 이번 프레임이 새로 구운 글리프를 아틀라스 텍스처에 올린다. **올린 영역 수**를 준다.
    pub fn uploadAtlasRegions(self: *Host, frame: maru.renderer.RenderFrame) usize {
        return uploadFrameRegions(self.pipeline, frame);
    }

    /// 프레임의 글리프를 셀 배열 **뒤에 잇는다.** 배경 쿼드를 앞에 넣고 싶으면 부르기 전에 넣는다 —
    /// 그리는 순서가 곧 z 순서다.
    pub fn appendGlyphCells(
        self: *const Host,
        allocator: std.mem.Allocator,
        frame: maru.renderer.RenderFrame,
        colors: maru.renderer.metal_frame.CellColors,
        cells: *std.ArrayList(d3d11_cells.Cell),
    ) !usize {
        return self.appendGlyphCellsAt(allocator, frame, colors, 0, 0, cells);
    }

    /// 같은 일을 하되 프레임을 **창의 특정 픽셀 자리**에 놓는다(§2m.31 — 터미널이 도크 옆에 선다).
    ///
    /// 원점은 셀마다 찍는다 — `cellFromNative` 가 `origin + col*cell_w` 로 자리를 만들기 때문이다.
    /// 그 찍는 일은 **중립이 소유한다**(`metal_frame.setCellsPaneOrigin`): 두 필드 중 하나만 쓰면
    /// 프레임이 대각선으로 어긋난다.
    pub fn appendGlyphCellsAt(
        self: *const Host,
        allocator: std.mem.Allocator,
        frame: maru.renderer.RenderFrame,
        colors: maru.renderer.metal_frame.CellColors,
        origin_x_px: u32,
        origin_y_px: u32,
        cells: *std.ArrayList(d3d11_cells.Cell),
    ) !usize {
        const native = try maru.renderer.metal_frame.buildNativeCellsFromGlyphQuads(
            allocator,
            frame.glyph_quad_frame,
            frame.draw_list.cells,
            colors,
        );
        defer allocator.free(native);
        maru.renderer.metal_frame.setCellsPaneOrigin(native, origin_x_px, origin_y_px);
        try cells.ensureUnusedCapacity(allocator, native.len);
        for (native) |n| cells.appendAssumeCapacity(win32_terminal.cellFromNative(n, self.cell_w, self.cell_h, self.atlas_w, self.atlas_h));
        return native.len;
    }

    /// 표면 모듈이 쓰는 조각들만 모아 준다(`win32_scm_surface.Ctx`). **창 전체를 뷰포트로 준다** —
    /// 스모크는 표면 하나만 띄우기 때문이다. 합성된 앱은 도크 사각형을 직접 채운다.
    /// 표면 모듈이 쓰는 조각들만 모아 준다. **창 전체를 뷰포트로 준다** — 스모크는 표면 하나만
    /// 띄우기 때문이다. 합성된 앱은 도크 사각형을 직접 채운다.
    pub fn surfaceCtx(self: *Host) SurfaceCtx {
        return .{
            .renderer_state = &self.renderer_state,
            .rasterizer = self.rasterizer,
            .pipeline = self.pipeline,
            .atlas_w = &self.atlas_w,
            .atlas_h = &self.atlas_h,
            .cell_w = self.cell_w,
            .cell_h = self.cell_h,
            .viewport_w = self.initial.width_px,
            .viewport_h = self.initial.height_px,
        };
    }

    /// 이번 프레임의 창 이벤트. **스왑체인 크기 맞추기는 여기서 한다** — 그것을 호출자마다
    /// 되풀이하면 하나가 빼먹는다(형제 스모크 셋 중 하나가 실제로 빼먹어 크기 변경 뒤 표현이
    /// 깨졌다). 나머지는 그대로 넘겨 **표면이 자기 입력을 해석**하게 한다.
    pub fn poll(self: *Host) ![]const win32_window.WindowEvent {
        const events = self.window.poll();
        for (events) |ev| switch (ev) {
            .resized => |r| try self.present.resize(r.width_px, r.height_px),
            else => {},
        };
        return events;
    }

    /// 창을 닫으라는 신호가 왔는가. `poll` 이 준 이벤트에서 `close_requested` 를 본 것과 같은 뜻이다.
    pub fn quitting(self: *const Host) bool {
        return self.window.quit_requested;
    }

    /// 셀 배열 한 벌을 한 프레임 그린다. 표현 간격(16ms)도 여기서 든다 — 표면마다 달라질 이유가 없다.
    pub fn drawFrame(self: *Host, cells: []const d3d11_cells.Cell, clear_argb: u32) !void {
        try self.present.beginFrame(d3d11_present.clearColorFromArgb(clear_argb));
        try self.pipeline.draw(cells, self.present.width_px, self.present.height_px);
        try self.present.present(false);
        _ = usleep(16_000);
    }

    /// 같은 셀 배열을 `frames` 번 표현한다. 창이 닫히거나 종료를 요청하면 일찍 끝난다.
    /// **실제로 표현한 프레임 수**를 준다.
    ///
    /// 셀을 다시 만들지 않으므로 창을 키워도 행이 더 보이지는 않는다 — 정적 스모크의 한계이지 잘못
    /// 그리는 것이 아니다. **입력에 반응해야 하는 표면은 `poll`·`drawFrame` 으로 자기 루프를 돈다.**
    pub fn presentLoop(self: *Host, cells: []const d3d11_cells.Cell, clear_argb: u32, frames: usize) !usize {
        var close_requested = false;
        var n: usize = 0;
        while (n < frames and !self.quitting() and !close_requested) : (n += 1) {
            for (try self.poll()) |ev| switch (ev) {
                .close_requested => close_requested = true,
                else => {},
            };
            try self.drawFrame(cells, clear_argb);
        }
        return n;
    }
};

/// 표현 사이 간격. **`main.zig` 가 쓰던 것과 같은 것**을 쓴다 — 리팩터가 타이밍을 바꾸면 등가성
/// 대조에서 프레임 수가 흔들린다.
extern "c" fn usleep(usec: c_uint) c_int;

/// 어느 단계에서 섰는지 사람이 읽을 수 있게. 스모크마다 같은 문장을 다시 쓰지 않게 모아 둔다.
pub fn reportSetupFailure(stderr: *std.Io.Writer, command: []const u8) !void {
    switch (last_stage) {
        .font => try stderr.print(
            "maru {s}: could not set up the font({s}, HRESULT 0x{X:0>8})\n",
            .{ command, @errorName(last_error), @as(u32, @bitCast(dwrite_font.last_hresult)) },
        ),
        .window => {
            try stderr.print(
                "maru {s}: could not create the window({s}, Win32 error {d})\n",
                .{ command, @errorName(last_error), win32_window.last_create_error },
            );
            if (win32_window.last_create_error == 8)
                try stderr.writeAll("  error 8 (ERROR_NOT_ENOUGH_MEMORY) usually means the desktop heap is exhausted - check how many processes this session has.\n");
        },
        .present => try stderr.print(
            "maru {s}: could not set up the present path({s}, HRESULT 0x{X:0>8})\n",
            .{ command, @errorName(last_error), @as(u32, @bitCast(d3d11_present.last_hresult)) },
        ),
        .pipeline => {
            try stderr.print(
                "maru {s}: could not set up the cell pipeline({s}, HRESULT 0x{X:0>8})\n",
                .{ command, @errorName(last_error), @as(u32, @bitCast(d3d11_cells.last_hresult)) },
            );
            if (d3d11_cells.shaderError().len > 0)
                try stderr.print("  shader compiler: {s}\n", .{d3d11_cells.shaderError()});
        },
    }
    try stderr.flush();
}

/// **아틀라스가 커졌으면 파이프라인 텍스처를 맞춘다.** 안 그러면 UV 가 옛 크기 기준이라 글자가
/// 엉뚱한 자리를 가리킨다.
///
/// `Host` 밖으로 낸 이유는 **호스트 없이 그리는 자리가 생겼기 때문**이다 — 합성된 앱 루프
/// (§2m.31~)는 자기 창·스왑체인·파이프라인을 직접 들고 있어 `Host` 를 안 쓴다. 규칙을 두 벌로
/// 두면 한쪽만 고쳐진다.
pub fn syncAtlasTexture(
    pipeline: *d3d11_cells.CellPipeline,
    renderer_state: *renderer.RendererState,
    atlas_w: *u32,
    atlas_h: *u32,
) !void {
    const now_w = renderer_state.atlas.config.atlas_width_px;
    const now_h = renderer_state.atlas.config.atlas_height_px;
    if (now_w != atlas_w.* or now_h != atlas_h.*) {
        try pipeline.resizeAtlas(now_w, now_h);
        atlas_w.* = now_w;
        atlas_h.* = now_h;
    }
}

/// 프레임이 새로 구운 글리프를 텍스처에 올린다. **올린 영역 수**를 준다.
///
/// **프레임을 버리기 전에 불러야 한다.** 업로드 목록은 그 프레임과 함께 사라지고, 아틀라스 CPU
/// 캐시는 그 글리프를 "이미 있다" 고 판단하므로 **다른 프레임도 다시 안 올린다** — 실측으로 그렇게
/// 도크와 터미널 글자가 함께 깨졌다(§2m.32).
pub fn uploadFrameRegions(pipeline: *d3d11_cells.CellPipeline, frame: renderer.RenderFrame) usize {
    var n: usize = 0;
    const rf = frame.glyph_raster_frame;
    for (rf.uploads) |up| {
        const bytes = rf.pixels[up.bytes_offset..][0..up.byte_count];
        pipeline.uploadAtlasRegion(up.slot.x_px, up.slot.y_px, up.slot.width_px, up.slot.height_px, bytes, up.bytes_per_row) catch continue;
        n += 1;
    }
    return n;
}

/// `chrome.draw.Op` 목록을 셀로 내린다 — **단색 사각 먼저, 글리프 나중**(그리는 순서가 곧 z 순서).
///
/// 편집기(§2m.22)와 소스 컨트롤(§2m.26)이 **같은 것을 쓴다.** 두 벌로 적으면 한쪽만 고쳐지고, 그
/// 증상은 "한 표면에서만 배경이 안 덮인다" 라 눈으로 잘 안 걸린다.
///
/// 그라디언트·테두리는 이 셰이더에 없으므로 **세어서 남긴다**(`dropped`) — 조용히 단색으로 그리면
/// 화면이 틀린 채로 그럴듯해진다.
/// 이 quad 가 **그릴 테두리**를 갖고 있나. 역할만으로 판정하면 안 된다 — `PaintStyle` 은 기본
/// 역할(`.divider`)을 늘 싣고 **폭이 0** 인 경우가 흔하다. 그것까지 "테두리 있음" 으로 세면 이 셰이더가
/// 못 그리는 것으로 오해해 **quad 를 통째로 버린다**: 실측으로 에이전트 목록의 **스크롤바 track·thumb
/// 둘 다** 그렇게 사라졌다(§2m.94 — 굴러가는데 막대가 안 보였다).
fn hasDrawableBorder(q: chrome.draw.Op.Quad) bool {
    if (q.border_role == null) return false;
    for (q.border_widths) |w| {
        if (w != 0) return true;
    }
    return false;
}

/// 두 사각형의 교집합. 겹치지 않으면 `null` — 호출부가 그 op 을 버린다.
fn intersect(a: chrome.draw.Rect, b: chrome.draw.Rect) ?chrome.draw.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + @as(i32, @intCast(a.w)), b.x + @as(i32, @intCast(b.w)));
    const y1 = @min(a.y + @as(i32, @intCast(a.h)), b.y + @as(i32, @intCast(b.h)));
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

pub fn appendChromeOps(
    allocator: std.mem.Allocator,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    clip_w: u32,
    clip_h: u32,
    cells: *std.ArrayList(d3d11_cells.Cell),
) !struct { text: usize, fill: usize, dropped: usize } {
    var n_text: usize = 0;
    var n_fill: usize = 0;
    var n_drop: usize = 0;
    for (ops) |op| {
        const rect: chrome.draw.Rect, const role: chrome.tokens.ColorRole, const alpha: u8, const radii: [4]u16 = switch (op) {
            .text => {
                n_text += 1;
                continue;
            },
            .clip => continue,
            .fill => |f| .{ f.rect, f.role, f.alpha, .{ 0, 0, 0, 0 } },
            .quad => |q| if (q.gradient == .solid and !hasDrawableBorder(q)) blk: {
                // **quad 는 자기 뷰포트를 싣고 온다**(`draw.Op.Quad.clip` — published tree 의
                // `effective_clip` 그대로). 그것을 안 쓰면 스크롤 목록의 배경·pill 이 헤더 위로
                // 올라온다 — 목록이 굴러가기 시작한 순간 보였다(§2m.92).
                const r = if (q.clip) |c| intersect(q.rect, c) orelse {
                    n_drop += 1;
                    continue;
                } else q.rect;
                break :blk .{ r, q.fill_role, q.alpha, q.corner_radii };
            } else {
                n_drop += 1;
                continue;
            },
            else => {
                n_drop += 1;
                continue;
            },
        };
        n_fill += 1;
        const x0 = @max(rect.x, 0);
        const y0 = @max(rect.y, 0);
        const x1 = @min(rect.x + @as(i32, @intCast(rect.w)), @as(i32, @intCast(clip_w)));
        const y1 = @min(rect.y + @as(i32, @intCast(rect.h)), @as(i32, @intCast(clip_h)));
        if (x1 <= x0 or y1 <= y0) continue;
        const rgb = tk.get(role);
        const argb = (@as(u32, alpha) << 24) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
        try cells.append(allocator, d3d11_cells.solidCell(
            @floatFromInt(x0),
            @floatFromInt(y0),
            @floatFromInt(x1 - x0),
            @floatFromInt(y1 - y0),
            d3d11_cells.colorFromArgb(argb),
            .{ @floatFromInt(radii[0]), @floatFromInt(radii[1]), @floatFromInt(radii[2]), @floatFromInt(radii[3]) },
        ));
    }
    return .{ .text = n_text, .fill = n_fill, .dropped = n_drop };
}
