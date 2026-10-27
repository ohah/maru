# Trust and environment-name picker IME verification

`mise exec -- zig build test-trust-picker-ime -j2` runs native range/owner/OOM tests,
the existing C/Zig ABI contract, neutral models in Debug/ReleaseFast, and independent
synthetic artifact controls. These do not replace physical input or candidate pixels.

`python3 tools/trust-picker-ime/mutations.py --output <new-external-directory>`
checks seven compile-valid product mutations with normal/restored controls.

Run the private trust scene first:

```sh
python3 tools/trust-picker-ime/run.py --output <new-external-directory> --mode diagnostic
```

Reuse its fixed app for the environment-name scene:

```sh
MARU_TRUST_IME_SCENE=env_names python3 tools/trust-picker-ime/run.py \
  --app <Maru.app/Contents/MacOS/maru-macos-app> \
  --output <new-external-directory> --mode diagnostic
```

The launcher creates a private HOME, two denied trust records, and a clean text
file. Only private launcher controls and fixed system paths are passed explicitly;
user environment values are not evidence inputs. Trust mode uses the ordinary
trust list and current-decision management path. Environment mode uses the
ordinary name list with shell-environment loading disabled. Korean/Hanja searches
in that ASCII-only name scene intentionally return no rows.

Both scenes use actual two-set Korean HID, five candidate cancellations and Hanja
selection. A separate Return opens management in trust mode or closes the name
list in environment mode. Management is cancelled with an actual Escape, never
confirmed. Physical slash input must return to the same unmodified source editor.
The private trust records and original disk file must remain unchanged.

Use `--mode live` only after granting Screen Recording to the exact staged app in
`run/manifest.json`. It verifies independent candidate PNG/hash/OCR and raw
window/anchor evidence. Diagnostic success is not pixel proof. Keep all raw
artifacts outside the repository and upload images only to the PR body.
