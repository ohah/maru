# Separately vendored third-party source

`pcre2-10.48.tar.gz` is the official PCRE2 10.48 release source archive:

- URL: <https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.48/pcre2-10.48.tar.gz>
- SHA-256: recorded in `pcre2-10.48.sha256`

It is kept outside `build.zig.zon` because Zig 0.17 compiles declared package
build scripts while configuring the package graph, and PCRE2 10.48's upstream
script uses the removed `Build.build_root` API. Maru builds the pinned archive's
PCRE2 8-bit static sources directly in `build.zig`.
