# Recovery picker IME verification

Run `mise exec -- zig build test-recovery-picker-ime -j2` for neutral models,
AppSession range/owner/failure tests and synthetic verifier controls. These are
separate from physical input and OS candidate pixels.

Run `python3 tools/recovery-picker-ime/mutations.py --output <new-external-directory>`
for five compile-valid product mutations plus normal and restored controls.

Run `python3 tools/recovery-picker-ime/run.py --output <new-external-directory> --mode diagnostic`
to build an isolated app copy. It creates two backups through the existing recovery
store in a private HOME/root, uses real two-set Korean HID, cancels five candidate
windows, selects Hanja, then restores only after a separate Return. The restored
copy must be dirty, occupy a new surface, accept a physical slash, and leave both
original disk files unchanged.

The same fixed app can be reused with `--app <Maru.app/Contents/MacOS/maru-macos-app>`.
Use `--mode live` for independent candidate PNG/hash/OCR checks after granting
Screen Recording to that exact staged app. Diagnostic success is not pixel proof.
The runner records its immutable staged app path in `run/manifest.json`.

Evidence and screenshots belong outside the repository. Attach selected images
to the PR body instead of committing them.
