//! Wire names shared by the executable dispatcher and native child launchers.
//! This contract grants no platform capability: POSIX argument parsing and
//! native session-host execution remain in their platform adapters.

pub const session_host = struct {
    pub const subcommand = "__session-host";
};

pub const notification_runtime = struct {
    pub const child_command = "__notification-release-runtime";
    pub const receipt_schema = "maru.session-host-notification-runtime-preparation.v1";
};
