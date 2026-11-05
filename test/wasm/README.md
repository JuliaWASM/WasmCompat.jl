# Wasm checks

One small program per extension (`toml.jl`, `logging.jl`, `tar.jl`, `artifacts.jl`), compiled by WasmCodegen with
`trim = :safe` and run on Node's WASI (`run.mjs`); `check.sh NAME` diffs its output with the same program run natively.

    WCG_JS=<WasmCodegen.jl>/js JULIA=julia NODE=node JULIA_PROJECT=<env with WasmCodegen, WasmCompat> ./check.sh toml
    ... PCRE2=1 ./check.sh tar         # Tar's error messages use a regex: Base's Regex on PCRE2
    ... PCRE2=1 ./check.sh regex       # Base's Regex API, compile errors, Pkg's semver patterns, Tar's path checks
    ... PCRE2=1 ./check.sh corpus      # 69 patterns, from ordinary to PCRE-only constructs, through eachmatch, keys, replace

`PCRE2=1` needs PCRE2_wasm_jll in the project (with its standalone module, 10.46.0+1 or later) and WasmCodegen
with `Config(foreign_functions)` and `Config(import_libraries)`.

Expected differences: `toml.jl`'s last line (a long integer literal parses as a `BigInt` natively, an overflow error
in Wasm; see the README's *Differences*); `regex.jl`'s `(?R)` line ("nested recursion at the same subject position"
from PCRE2 without a JIT, "JIT stack limit reached" from native Julia's JIT; see the README's *Regex*); and `tar.jl`
traps at `Tar.list` (see the README's *Requirements and known limits*; it needs `julia_io` for file modes too).
