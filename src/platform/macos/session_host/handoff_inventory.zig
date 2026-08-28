//! Session-host exec handoff owner-field inventory(U0).
//!
//! 이 파일은 codec이 아니다. 실행 중 host를 `exec`하면 userspace 상태가 전부 사라지므로, handoff와 관련된 owner
//! type의 필드가 새로 생겼을 때 "기본값으로 복구되겠지" 하고 조용히 누락되는 것을 먼저 막는다. 각 필드는 정확히 한
//! disposition에 있어야 하며, 미분류·중복·삭제된 이름이 있으면 compile error다.
//!
//! 실제 encode/decode와 logical round-trip은 U1이다. 특히 `reconstructed`는 값이 중요하지 않다는 뜻이 아니라,
//! 별도 runtime DTO에서 pointer graph/allocator/thread/derived index를 다시 만든다는 뜻이다. `must_be_empty`는 U2
//! quiesce가 exec 전에 증명해야 하는 전제다. 단일 출처: docs/session-host-upgrade.md §8·§11.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
// Darwin syscall owner types는 non-macOS compile에서 import 자체를 하지
// 않는다. 개별 field validate만 조건부로 두면 import 분석 중 fstatat 등
// Darwin API에서 먼저 깨져 portability CI가 inventory를 수집하지 못한다.
const RuntimeManager = if (builtin.os.tag == .macos)
    @import("runtime_manager.zig").RuntimeManager
else
    void;

pub const Disposition = enum {
    /// Logical value/content is part of the versioned handoff state.
    serialized,
    /// Process-local object is rebuilt from already-serialized logical records.
    reconstructed,
    /// Kernel resource survives exec through an explicitly validated inherited-fd slot, never by persisting its numeric fd as identity.
    inherited_resource,
    /// Quiesce must prove the field has no in-flight state before encode.
    must_be_empty,
};

pub const Group = struct {
    disposition: Disposition,
    fields: []const []const u8,
    why: []const u8,
};

fn fieldExists(comptime T: type, comptime wanted: []const u8) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, wanted)) return true;
    }
    return false;
}

fn occurrences(comptime groups: []const Group, comptime wanted: []const u8) usize {
    var count: usize = 0;
    inline for (groups) |group| {
        inline for (group.fields) |name| {
            if (std.mem.eql(u8, name, wanted)) count += 1;
        }
    }
    return count;
}

/// Compile-time exhaustive field classifier. A field addition, stale name, or duplicate classification stops the build.
pub fn validate(comptime T: type, comptime type_name: []const u8, comptime groups: []const Group) void {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError(type_name ++ " handoff inventory requires a struct");

    inline for (info.@"struct".fields) |field| {
        const count = occurrences(groups, field.name);
        if (count == 0) @compileError(type_name ++ "." ++ field.name ++ " is missing from handoff inventory");
        if (count != 1) @compileError(type_name ++ "." ++ field.name ++ " appears more than once in handoff inventory");
    }
    inline for (groups) |group| {
        if (group.fields.len == 0) @compileError(type_name ++ " has an empty handoff inventory group");
        if (group.why.len == 0) @compileError(type_name ++ " handoff inventory group needs a reason");
        inline for (group.fields) |name| {
            if (!fieldExists(T, name)) @compileError(type_name ++ "." ++ name ++ " no longer exists");
        }
    }
}

const TerminalCore = maru.terminal.TerminalCore;
const Screen = @FieldType(TerminalCore, "screen");
const Scrollback = @FieldType(Screen, "sb");
const ScrollbackPagePtr = std.meta.Child(@FieldType(@FieldType(Scrollback, "pages"), "items"));
const ScrollbackPage = std.meta.Child(ScrollbackPagePtr);
const RowDesc = std.meta.Child(@FieldType(@FieldType(ScrollbackPage, "descs"), "items"));
const PtySession = maru.pty.PtySession;
const LivePtySession = maru.app.LivePtySession;
const PtyReader = maru.app.PtyReader;
const PtyEventQueue = maru.app.PtyEventQueue;
const PtyWriteQueue = maru.app.PtyWriteQueue;
const CoreCommandQueue = maru.app.CoreCommandQueue;
const TerminalRuntimeRegistry = @import("registry.zig").TerminalRuntimeRegistry;
const RuntimeEntry = @import("registry.zig").RuntimeEntry;
const SocketServer = if (builtin.os.tag == .macos)
    @import("socket_server.zig").SocketServer
else
    void;
const Surface = maru.session.Surface;
const LiveSurfaceTerminal = maru.app.LiveSurface.Terminal;
const LiveRegistry = maru.app.in_process_term_backend.LiveRegistry;
const LiveRegistryEntry = LiveRegistry.Entry;
const SurfaceRuntime = maru.app.SurfaceRuntime;
const SurfaceRuntimeLink = std.meta.Child(@FieldType(@FieldType(SurfaceRuntime, "links"), "items"));
const KittyImageStorage = @FieldType(TerminalCore, "kitty_images");
const KittyImage = @FieldType(@FieldType(KittyImageStorage, "map").KV, "value");
const StoredPlacement = std.meta.Child(@FieldType(@FieldType(TerminalCore, "kitty_placements"), "items"));
const KittyGraphicsCommand = std.meta.Child(@FieldType(TerminalCore, "kitty_chunk_cmd"));
const Cell = maru.terminal.Cell;
const Style = maru.terminal.Style;

pub const terminal_core_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{
            "size",
            "screen",
            "utf8_tail",
            "utf8_tail_len",
            "parser",
            "csi_params",
            "csi_param_count",
            "csi_has_digit",
            "csi_marker",
            "csi_intermediate",
            "csi_overflow",
            "scroll_top",
            "scroll_bottom",
            "origin_mode",
            "alt_active",
            "application_cursor_keys",
            "application_keypad",
            "alternate_scroll",
            "bracketed_paste",
            "focus_events",
            "mouse_tracking",
            "mouse_format",
            "sync_output",
            "sync_esu_count",
            "sync_bsu_count",
            "kitty_flags",
            "grapheme_cluster_mode",
            "cursor_visible",
            "cursor_shape",
            "cursor_blink",
            "default_cursor_shape",
            "cursor_shape_overridden",
            "saved_screen",
            "csi_subparam",
            "semantic_state",
            "last_command_exit",
            "shell_events",
            "shell_events_overflow",
            "ambiguous_wide",
            "emoji_wide",
            "view_offset",
            "selection_anchor",
            "selection_head",
            "selection_block",
            "link_store",
            "pen_link",
            "grapheme_store",
            "osc_buffer",
            "osc_overflow",
            "osc_large_ok",
            "dcs_buffer",
            "dcs_len",
            "dcs_overflow",
            "apc_buffer",
            "apc_overflow",
            "kitty_chunk",
            "kitty_chunk_cmd",
            "cell_width_px",
            "cell_height_px",
            "default_fg_rgb",
            "default_bg_rgb",
            "default_fg_override",
            "default_bg_override",
            "palette_override",
            "config_palette",
            "clipboard_write",
            "clipboard_write_rejected",
            "clipboard_read_pending",
            "clipboard_read_target",
            "notification_pending",
            "notification_write_rejected",
            "notification_title",
            "notification_body",
            "agent_progress",
            "charset_g0",
            "charset_g1",
            "charset_gl",
            "escape_intermediate_byte",
            "tabstops",
            "bell_pending",
            "insert_mode",
            "autowrap",
            "reverse_screen",
            "kitty_images",
            "kitty_placements",
            "cwd",
            "cwd_host",
            "ssh_remote_dest",
            "title",
            "title_generation",
            "observer_generation",
        },
        .why = "terminal logical state, parser continuation, durable stores, and user-visible pending state must survive exec",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{
            "allocator",
            "owner_dbg",
            "dirty",
            "link_ids",
            "grapheme_ids",
            "placement_views",
            "image_views",
            "viewport_cells",
            "viewport_prompt_marks",
            "reflow_cells",
            "reflow_wrapped",
            "reflow_prompt_marks",
            "notification_generation",
        },
        .why = "allocator/debug ownership, dirty/scratch projections, store-derived indexes, and notification admission token are rebuilt; upgrade requires all clients/control queues empty so no old token survives",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{"response"},
        .why = "U2 must flush the core reply into the PTY before the reader reaches its handoff safe point",
    },
};

pub const screen_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{
            "cells",
            "wrapped",
            "prompt_marks",
            "sb",
            "cursor",
            "pen",
            "pending_wrap",
            "last_print",
            "last_printed_cp",
            "saved_cursor",
        },
        .why = "both primary and alternate screens need exact grid, cursor, wrap, prompt, pen, and scrollback state",
    },
};

pub const scrollback_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{
            "pages",
            "count",
            "cap",
            "evicted_abs",
            "pushed_abs",
            "rewrap_pending",
        },
        .why = "live rows and absolute row identity are logical state; page allocation layout is not",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{ "pool", "arena_alloc" },
        .why = "free pages and allocator identity are process-local capacity optimizations",
    },
};

pub const scrollback_page_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "cells", "descs", "head", "used", "abs_start" },
        .why = "codec projects only the live descriptor window and referenced cells into logical rows; raw stale arena layout is never dumped",
    },
};

pub const row_desc_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "off", "len", "wrapped", "prompt" },
        .why = "each descriptor defines the exact row slice and its wrap/prompt semantics",
    },
};

pub const kitty_image_storage_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "total_bytes", "gen_counter", "limit" },
        .why = "storage accounting, upload generation monotonicity, and the runtime memory policy survive migration",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{"map"},
        .why = "hash buckets are rebuilt from exhaustive image records after aggregate byte validation",
    },
};

pub const kitty_image_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "id", "width", "height", "bpp", "data", "generation" },
        .why = "image identity, geometry, pixels, and renderer cache generation are logical state",
    },
};

pub const stored_placement_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{
            "image_id",
            "placement_id",
            "anchor_row",
            "anchor_col",
            "cell_x_offset",
            "cell_y_offset",
            "src_x",
            "src_y",
            "src_width",
            "src_height",
            "columns",
            "rows",
            "z",
        },
        .why = "placement identity, absolute anchor, crop, extent, and stacking order must remain exact",
    },
};

pub const kitty_graphics_command_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{
            "action",
            "format",
            "width",
            "height",
            "image_id",
            "more",
            "compression",
            "placement_id",
            "src_x",
            "src_y",
            "src_width",
            "src_height",
            "cell_x_offset",
            "cell_y_offset",
            "columns",
            "rows",
            "z",
            "no_cursor_move",
            "delete_what",
        },
        .why = "a partial kitty transfer must resume with the exact parsed control command",
    },
};

pub const style_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{
            "foreground",
            "background",
            "bold",
            "dim",
            "italic",
            "underline",
            "underline_double",
            "strikethrough",
            "overline",
            "reverse",
            "blink",
            "conceal",
            "underline_color",
        },
        .why = "screen cells and cursor pen must preserve every terminal rendition attribute",
    },
};

pub const cell_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "codepoint", "style", "width", "continuation", "grapheme_id", "link" },
        .why = "cell text, width topology, style, and store identities are logical screen state",
    },
};

pub const pty_session_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "child_pid", "size" },
        .why = "same-PID exec preserves parentage while the logical record verifies the expected child and canonical size",
    },
    .{
        .disposition = .inherited_resource,
        .fields = &.{"master_fd"},
        .why = "the numeric fd is not durable identity; an inherited slot is fstat-validated and rebound after exec",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{ "wake_read_fd", "wake_write_fd", "owns_child_lifecycle" },
        .why = "wake pipes are recreated and target sessions remain non-owning until the host-global graph commits",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{ "exited", "closing", "reaping" },
        .why = "live upgrade eligibility requires no destructive close, consumed exit, or waitpid critical section",
    },
};

pub const pty_reader_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{"pty_id"},
        .why = "the reader must be rebound to the same logical PTY",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{
            "allocator",
            "session",
            "queue",
            "core",
            "core_mutex",
            "io",
            "write_queue",
            "command_queue",
            "processing",
            "pause_state",
            "start_released",
            "start_aborted",
            "start_gate_reached",
            "output_byte_counter",
        },
        .why = "all pointers, synchronization context, processing latch, and diagnostic byte counter are rebuilt after the quiesced runtime graph exists",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{ "thread", "transfer_out", "transfer_out_head" },
        .why = "U2 non-destructive pause joins the old thread and proves its owned response transfer buffer is empty before encode",
    },
};

pub const pty_event_queue_groups = [_]Group{
    .{
        .disposition = .reconstructed,
        .fields = &.{ "io", "allocator", "items", "head", "mutex", "not_empty", "not_full", "wake_notifier" },
        .why = "capacity and synchronization storage are rebuilt after U2 drains coalesced output signals",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{ "len", "closed" },
        .why = "no terminal event may be discarded and a live queue cannot be closed",
    },
};

pub const pty_write_queue_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{"cap"},
        .why = "the restored queue retains its configured bounded backpressure capacity",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{ "io", "allocator", "mutex", "not_full", "enqueued_total", "consumed_total" },
        .why = "after the empty/equal fence gate, synchronization and monotonic counters restart together at zero",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{ "bytes", "head", "closed" },
        .why = "all admitted input bytes must be written exactly once and the queue must remain live",
    },
};

pub const core_command_queue_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{"cap"},
        .why = "the restored command queue retains its configured bounded capacity",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{ "io", "allocator", "mutex", "not_full", "debug" },
        .why = "synchronization and debug policy are process-local",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{ "items", "head", "closed" },
        .why = "all admitted commands and input fences must be applied before exec",
    },
};

pub const runtime_entry_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "id", "cols", "rows", "resize_generation" },
        .why = "runtime identity and canonical geometry generation remain stable across exec",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{ "controller_generation", "controller_sequence", "resize_seq_seen", "runtime" },
        .why = "v1 upgrade requires every attachment and authority event queue to be empty, so the disconnected controller epoch and connection-local resize sequence reset while the opaque runtime pointer is rebound",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{ "controller", "observers" },
        .why = "v1 upgrade is eligible only with zero controller and observer attachments",
    },
};

pub const terminal_runtime_registry_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{"membership_generation"},
        .why = "runtime inventory ABA authority must remain monotonic across same-PID exec handoff",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{ "allocator", "entries", "live_grid_cells", "limits" },
        .why = "the hash table, entry pointers, aggregate charge, and product limits are rebuilt from exhaustive RuntimeEntry records and binary constants",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{"membership_generation_exhausted"},
        .why = "an exhausted inventory authority cannot safely enter a live upgrade",
    },
};

pub const socket_server_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{"host_id"},
        .why = "workspace runtime handles require the same host identity after upgrade",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{
            "listen_fd",
            "server_uid",
            "socket_path",
            "socket_dev",
            "socket_ino",
            "allocator",
            "registry",
            "runtime_ops",
            "upgrade_ops",
            "host_status",
            "admission_gate",
            "owner_tick_ctx",
            "owner_tick",
            "owner_wake_fd",
            "owner_wake_ctx",
            "owner_wake_drain",
            "subscriptions",
        },
        .why = "the listener, target build status, process-local callbacks, gate pointer, and subscription table are rebuilt only after the complete runtime graph is prepared; poll_owner is the sole transient connection/upgrade-marker authority and is drained before capture",
    },
};

pub const surface_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "id", "core" },
        .why = "the host-local surface identity and complete terminal core survive through logical records",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{ "title", "custom_name", "cwd", "command", "process_state", "core_mutex" },
        .why = "host surfaces use placeholder metadata while TerminalCore owns cwd/title; UI names and commands remain workspace authority, running is an eligibility invariant, and the mutex is process-local",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{ "preedit", "remote" },
        .why = "host runtimes have no client-local IME overlay and cannot themselves be remote-backed",
    },
};

pub const live_surface_terminal_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "surface", "live_pty" },
        .why = "the terminal arm owns the two exhaustively inventoried logical runtime components",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{"internal_allocator"},
        .why = "bundle allocation identity is process-local",
    },
};

pub const live_registry_entry_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "surface_id", "generation" },
        .why = "registry keys and generation remain stable",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{"runtime"},
        .why = "the heap-pinned terminal arm pointer is rebound after all records decode",
    },
};

pub const live_registry_groups = [_]Group{
    .{
        .disposition = .reconstructed,
        .fields = &.{ "allocator", "entries" },
        .why = "the owner registry allocation and pointers are rebuilt from exhaustive entry and terminal-arm records",
    },
};

pub const surface_runtime_link_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "surface_id", "pty_id" },
        .why = "routing identities remain stable across graph reconstruction",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{ "surface", "pty_io" },
        .why = "surface pointer and PTY vtable bind to restored objects",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{"trace_recorder"},
        .why = "v1 does not migrate a live trace writer or its file descriptor",
    },
};

pub const surface_runtime_groups = [_]Group{
    .{
        .disposition = .reconstructed,
        .fields = &.{ "allocator", "links", "debug_input" },
        .why = "the routing table is rebuilt from exhaustive link records and debug policy is re-read",
    },
};

pub const live_pty_session_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{"pty_id"},
        .why = "the runtime-to-PTY logical identity must be stable across pointer-graph reconstruction",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{
            "allocator",
            "io",
            "session",
            "queue",
            "write_queue",
            "command_queue",
            "write_io_ctx",
            "reader",
            "link",
        },
        .why = "pinned pointers, queues, runtime link, reader, and IO context are rebuilt from quiesced runtime records",
    },
    .{
        .disposition = .must_be_empty,
        .fields = &.{ "reader_finished", "reader_failed" },
        .why = "finished reader is a terminated or failed runtime and cannot enter the live upgrade set",
    },
};

pub const runtime_manager_groups = [_]Group{
    .{
        .disposition = .serialized,
        .fields = &.{ "next_handle", "notification_journal", "notification_metadata", "notification_permanent_drops" },
        .why = "restored handles must not collide with a handle issued before exec; host-lifetime notification IDs, pending delivery bits, and bounded drop evidence cannot reset at the exec boundary",
    },
    .{
        .disposition = .reconstructed,
        .fields = &.{
            "allocator",
            "io",
            "live_registry",
            "surface_runtime",
            "backend_impl",
            "host_registry",
            "foreground_cache",
            "observation_caches",
            "screen_changes",
            "bell_counts",
            "clipboards",
            "observed_reaped_children",
            "observed_last_child_exit_status",
            "notification_os_machine",
            "notification_os_adapter",
            "output_metrics_enabled",
            "observed_output_bytes",
            "observation_materializations",
            "observation_metrics_enabled",
            "observation_core_lock_acquisitions",
            "observation_core_lock_hold_total_ns",
            "observation_core_lock_hold_max_ns",
            "screen_metrics_enabled",
            "screen_snapshot_calls",
            "screen_delta_calls",
            "screen_owned_allocations",
            "screen_core_lock_acquisitions",
            "output_wake",
            // The successor re-derives this from its own invocation host_id, which upgrade validation forces to
            // equal the predecessor's, so the agent-hook instance segment it stamps on new children keeps the
            // same name across exec. Serializing it would add a second source for one identity.
            //
            // That re-derivation is enforced, not assumed: RuntimeManager.init takes the id as an argument, so a
            // restore path cannot construct a manager without deciding it. The first version of this comment was
            // written before that was true -- restore_activation built its manager without the id, and every child
            // spawned after an upgrade silently lost its hook identity. Adversarial review caught it.
            "hook_identity",
        },
        .why = "the self-referential manager graph, process-local output self-pipe, OS notification adapter/retry clock, derived canonical observation caches, and screen-change tokens are rebuilt in place from serialized host and runtime records; upgrade preflight requires zero attachments, so restored streams capture the successor token with their initial snapshot rather than inheriting a predecessor subscription frontier; pending_os remains authoritative in the serialized journal so an interrupted delivery is retried without success ack, while process-local backoff and diagnostic counters restart; bell, clipboard, and fixture-only diagnostic counters restart at zero; the agent-hook log identity (host id + cache base) is re-derived from the invocation that upgrade validation already pins to the same host_id",
    },
};

comptime {
    // TerminalCore alone has many fields; exhaustive name×rule duplicate checks intentionally exceed Zig's small default.
    @setEvalBranchQuota(100_000);
    validate(TerminalCore, "TerminalCore", &terminal_core_groups);
    validate(Screen, "Screen", &screen_groups);
    validate(Scrollback, "Scrollback", &scrollback_groups);
    validate(ScrollbackPage, "ScrollbackPage", &scrollback_page_groups);
    validate(RowDesc, "RowDesc", &row_desc_groups);
    validate(KittyImageStorage, "KittyImageStorage", &kitty_image_storage_groups);
    validate(KittyImage, "KittyImage", &kitty_image_groups);
    validate(StoredPlacement, "StoredPlacement", &stored_placement_groups);
    validate(KittyGraphicsCommand, "KittyGraphicsCommand", &kitty_graphics_command_groups);
    validate(Style, "Style", &style_groups);
    validate(Cell, "Cell", &cell_groups);
    // The inventory describes the concrete Darwin PTY owner. On non-macOS
    // targets `PtySession` is an API-compatible unsupported stub, so applying
    // Darwin field names to it would turn the portability facade itself into a
    // false compile failure.
    if (builtin.os.tag == .macos)
        validate(PtySession, "PtySession", &pty_session_groups);
    validate(PtyReader, "PtyReader", &pty_reader_groups);
    validate(PtyEventQueue, "PtyEventQueue", &pty_event_queue_groups);
    validate(PtyWriteQueue, "PtyWriteQueue", &pty_write_queue_groups);
    validate(CoreCommandQueue, "CoreCommandQueue", &core_command_queue_groups);
    validate(LivePtySession, "LivePtySession", &live_pty_session_groups);
    validate(RuntimeEntry, "RuntimeEntry", &runtime_entry_groups);
    validate(TerminalRuntimeRegistry, "TerminalRuntimeRegistry", &terminal_runtime_registry_groups);
    if (builtin.os.tag == .macos) {
        validate(RuntimeManager, "RuntimeManager", &runtime_manager_groups);
        validate(SocketServer, "SocketServer", &socket_server_groups);
    }
    validate(Surface, "Surface", &surface_groups);
    validate(LiveSurfaceTerminal, "LiveSurface.Terminal", &live_surface_terminal_groups);
    validate(LiveRegistryEntry, "LiveRegistry.Entry", &live_registry_entry_groups);
    validate(LiveRegistry, "LiveRegistry", &live_registry_groups);
    validate(SurfaceRuntimeLink, "SurfaceRuntime.Link", &surface_runtime_link_groups);
    validate(SurfaceRuntime, "SurfaceRuntime", &surface_runtime_groups);
}

test "handoff inventory classifies every owner field exactly once" {
    // The compile-time block is the assertion. Keep a runtime test so the dedicated session-host test output names the gate.
    try std.testing.expect(@typeInfo(TerminalCore).@"struct".fields.len > 0);
}
