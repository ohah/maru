#!/usr/bin/env python3
"""Run actual click/drag/Shift+Right selection and pointer-driven pane return."""
import os

# This selects only the private-copy driver; product input never reads this flag.
os.environ['MARU_ADDRESS_POINTER'] = '1'
import run as address_runner
import pointer_verify

address_runner.common.validate = pointer_verify.validate
address_runner.common.validate_diagnostic = pointer_verify.validate_diagnostic
if __name__ == '__main__':
    address_runner.common.main()
