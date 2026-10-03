//! Native SSH transport for the common file tree worker. The host installs it explicitly.
const maru = @import("maru");
const ssh_upload = @import("ssh_upload.zig");
pub const transport: maru.app.file_tree_backend.RemoteTransport = .{
    .runCapped = ssh_upload.runRemoteCapped,
    .list_script = ssh_upload.list_script,
};
