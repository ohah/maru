//! Provenance for the frozen same-major compatibility fixture.
//!
//! `source_revision` is the parent of the P5b3 controller-transfer commit. `source_sha256`
//! covers `session_host_pre_p5b3_v2.zig` exactly and is checked by the P5c3d sentinel before the
//! executable is launched. The semantic fingerprint names the negotiated wire facts that the
//! product must observe; it is not inferred from the current compatibility table.

pub const source_revision = "a9ed24855f6261303d6f467203bcfed183f27175";
pub const source_sha256 = "70f8daa67dcca1a3d758abc524524b84cd768d718c1a8f234982bc440cd7945b";
pub const expected_fingerprint = "mrsh-v2:screen-v2:controller-transfer-absent";
