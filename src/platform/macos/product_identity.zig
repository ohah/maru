//! Compile-time product identity shared by packaging and release provenance validation.
//! Keeping the bundle ID here prevents a signed plist and the validator from drifting independently.

pub const bundle_id = "dev.maru.apphost";
pub const bundle_version = "1";
