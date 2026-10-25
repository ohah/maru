"""Rename scene binds the common window proof to rename ownership and target writes."""
from pathlib import Path
from prepare import load
common = load('address_semantic_verifier', Path(__file__).resolve().parents[1] / 'address-ime/verify.py')
def validate(report, candidate, artifact_root=None):
    return common.validate(report, candidate, artifact_root, scene='rename')
def validate_diagnostic(report):
    return common.validate_diagnostic(report, scene='rename')
h = common.h
