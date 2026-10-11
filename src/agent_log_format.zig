//! Neutral value contract shared by PTY and session policy. No OS or allocation.
pub const Profile = enum {
    v1,
    v2,
    pub fn envValue(self: Profile) []const u8 {
        return switch (self) {
            .v1 => "1",
            .v2 => "2",
        };
    }
};
pub const local_env: [:0]const u8 = "MARU_AGENT_LOG_FORMAT";
pub const remote_env: [:0]const u8 = "LC_MARU_LOG_FORMAT";
