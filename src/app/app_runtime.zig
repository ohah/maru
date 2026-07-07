//! AppRuntime — 앱 인스턴스 전역 런타임 coordinator (L4, docs/window-surface-mobility.md §3·§8A.2).
//!
//! §3 목표 구조의 "registry와 graph를 함께 갱신하는 단일 정책 소유자"를 실체화한다(M3b). M2b까지 흩어져 있던
//! 앱 전역 소유 seam — surface_id allocator·live surface registry·라우팅 표 — 을 **하나의 coordinator 타입**으로
//! 묶는다(모듈-로컬 `var app_surface_ids`/`app_live_registry`의 정식화). 이 세 자원은 전부 **앱 인스턴스 전역**
//! (창보다 오래 산다)이라 한 곳에서 소유해야 cross-window 이동(M3d)이 surface_id 하나로 registry·라우팅을 조회한다.
//!
//! **레이어 규율**(§3·§8A.2): AppRuntime은 핸들 **수명만** L4로 들고, 이동 가부·drop target·정규화 같은 **정책**은
//! L2 순수 함수(`src/session`)를 호출해 결정한다 — 정책과 플랫폼 핸들을 한 god object에 섞지 않는다. M3b 시점엔
//! 아직 이동 로직(M3d)이 없어 정책 함수 호출이 없지만, 구조는 그 분리를 미리 지킨다(coordinator=소유, L2=정책).
//!
//! **인스턴스 소유**: L4 host가 앱 인스턴스당 하나를 소유한다. 현재 Zig엔 앱 전역 세션 coordinator가 없어(창마다
//! Swift가 `maru_macos_app_session_create`를 부른다) `app_session.zig`의 모듈-로컬 `var app_runtime`이 그 소유 seam이고,
//! 모든 `AppSession`(창)이 그 한 인스턴스의 세 필드를 포인터로 참조한다. 앱 전역 coordinator가 생기면 소유만 이관한다.
//!
//! **스레드**: 세 필드 전부 메인 스레드 전용이다(surface_id.zig·세션 트리 계약과 동일 — createTerm/destroyTerm/입력/
//! resize/tick pump는 전부 메인 이벤트다). 리더 스레드는 interactive 모드에서 `core_mutex` 아래 core에 **직접** 쓰고
//! (setProcessing) 라우팅 표를 건드리지 않으므로, 라우팅 앱-전역 승격과 리더는 독립이다(§8A.2 — pump만 재배선).

const std = @import("std");
const surface_id = @import("../session/surface_id.zig");
const live_surface_registry = @import("../session/live_surface_registry.zig");
const runtime_mod = @import("runtime.zig");
const live_pty = @import("live_pty.zig");

/// 앱 인스턴스 전역 런타임 자원 묶음(§8A.2 채택안). 세 필드는 전부 창보다 오래 사는 앱 전역 수명이라, 각 필드의
/// bookkeeping(카운터·entries 배열·links 배열 + registry가 소유하는 각 런타임 heap 슬롯)은 프로세스 전역
/// `smp_allocator`로 소유한다(`app_host_abi`가 AppSession을 만들 때 쓰는 것과 동일 — 프로덕션은 창 allocator도 smp라
/// 사실상 동일). 각 `LiveSurface`/`LivePtySession` **내부**(core·session·queue·owned string)는 그 런타임을 만든 창의
/// allocator가 소유한다(createTerm이 슬롯에 실어줌) — 두 allocator가 remove에서 각자 짝이 맞는다(M2b 분리의 유지).
pub const AppRuntime = struct {
    /// surface_id·pty_id 발급기 — 앱 전역 단조·비재사용(M0a). 모든 창이 공유해 멀티 창에서도 id가 유일하다.
    surface_ids: surface_id.SurfaceIdAllocator = .{},

    /// live surface 소유자(M2b/M3a) — `LiveSurface` 번들(surface + live_pty)을 surface_id 키드 heap 슬롯으로 소유한다.
    /// 창은 `surface_id`로 안정 슬롯을 참조만 한다. bookkeeping은 앱 전역이라 `smp_allocator`(위 주석의 allocator 분리).
    live_registry: live_surface_registry.LiveSurfaceRegistry(live_pty.LiveSurface) = .{ .allocator = std.heap.smp_allocator },

    /// 입력/resize/명령/PTY 이벤트 라우팅 표(M3b — per-window → 앱-전역). 링크가 `surface_id`로 keyed라, cross-window
    /// 이동은 라우팅을 전혀 안 건드리고(surface_id 불변) 목적지 창 메인 스레드가 **같은 표**를 조회한다(§8A.2). 창이
    /// 닫혀도 이 표를 deinit하지 않는다 — 그 창의 링크만 per-Term `closeAndDetach`로 detach하고 다른 창 링크는 살아 있다.
    routing: runtime_mod.SurfaceRuntime = .{ .allocator = std.heap.smp_allocator },
};
