//! Provenance for the frozen same-major compatibility fixture.
//!
//! `source_revision` is the parent of the P5b3 controller-transfer commit. `source_sha256`
//! covers `session_host_pre_p5b3_v2.zig` exactly and is checked by the P5c3d sentinel before the
//! executable is launched. The semantic fingerprint names the negotiated wire facts that the
//! product must observe; it is not inferred from the current compatibility table.

pub const source_revision = "a9ed24855f6261303d6f467203bcfed183f27175";
pub const source_sha256 = "0ab5fbfea2eb246591246b26e45e97641d6f0530735d82cf2080f76d41230252";
pub const expected_fingerprint = "mrsh-v2:screen-v2:controller-transfer-absent";
