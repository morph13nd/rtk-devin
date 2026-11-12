# RTK (Rust Token Killer)

RTK is installed on this machine. A `PreToolUse` hook rewrites supported
shell commands automatically (`git status` becomes `rtk git status`), and a
`PostToolUse` hook compresses exec output after it runs, so `exec` output is
already compact. Keep running commands normally; do not prefix `rtk`
yourself.

When output shows `[N lines elided]` or a `[full output: rtk recall <hash>]`
pointer, run `rtk recall <hash>` through `exec` to recover the full text if
you need it.

For workflows that would use built-in file or search tools (which bypass the
hook), prefer the RTK equivalents through `exec` to get the same compact
output:

- `rtk read <file>` instead of reading whole files
- `rtk grep <pattern>` / `rtk rg <pattern>` instead of broad greps
- `rtk find <pattern>` instead of wide file listings
- `rtk git <subcommand>`, `rtk test`, `rtk lint`, etc. for supported tools

Check savings with `rtk gain`. Full command list: `rtk --help`.
