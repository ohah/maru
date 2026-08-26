//! Product macOS adapter for daemon-internal UserNotifications delivery (P4 N2b2).

pub const delivery_api = @import("notification_os_delivery.zig");
const delivery = delivery_api;

const c = @cImport({
    @cInclude("session_host_notification_adapter.h");
});

pub const State = struct {
    pub fn adapter(self: *State) delivery.Adapter {
        return .{ .context = self, .submitFn = submit, .expireFn = expire };
    }

    fn submit(context: *anyopaque, request: delivery.Request) delivery.AdapterResult {
        _ = context;
        const hid_hi: u64 = @truncate(request.route.hid >> 64);
        const hid_lo: u64 = @truncate(request.route.hid);
        const rid_hi: u64 = @truncate(request.route.rid >> 64);
        const rid_lo: u64 = @truncate(request.route.rid);
        return switch (c.maru_session_host_notification_submit(
            hid_hi,
            hid_lo,
            rid_hi,
            rid_lo,
            request.route.eid,
            request.title.ptr,
            request.title.len,
            request.body.ptr,
            request.body.len,
            request.display_label.ptr,
            request.display_label.len,
        )) {
            c.MARU_NOTIFICATION_ACCEPTED => .accepted,
            c.MARU_NOTIFICATION_DENIED => .denied,
            c.MARU_NOTIFICATION_BUNDLE_MISSING => .bundle_missing,
            c.MARU_NOTIFICATION_ENTITLEMENT_MISSING => .entitlement_missing,
            c.MARU_NOTIFICATION_PENDING => .pending,
            else => .transient,
        };
    }

    fn expire(context: *anyopaque, route: delivery.Route) void {
        _ = context;
        c.maru_session_host_notification_expire(
            @truncate(route.hid >> 64),
            @truncate(route.hid),
            @truncate(route.rid >> 64),
            @truncate(route.rid),
            route.eid,
        );
    }
};
