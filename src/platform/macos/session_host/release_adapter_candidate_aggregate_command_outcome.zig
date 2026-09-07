//! Compatibility facade for the shared validator process outcome vocabulary.

const outcome_contract = @import("release_adapter_command_outcome");

pub const Outcome = outcome_contract.Aggregate;
pub const exitCode = outcome_contract.aggregateExitCode;
pub const stderrLine = outcome_contract.aggregateStderrLine;
