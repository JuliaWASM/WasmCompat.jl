# Wasm checks

One small program per extension (`toml.jl`, `logging.jl`, `tar.jl`, `artifacts.jl`), compiled by WasmCodegen with
`trim = :safe` and run on Node's WASI (`run.mjs`); `check.sh NAME` diffs its output with the same program run natively.

    WCG_JS=<WasmCodegen.jl>/js JULIA=julia NODE=node JULIA_PROJECT=<env with WasmCodegen, WasmCompat> ./check.sh toml
    ... ./check.sh tar julia_regex     # Tar's error messages use a regex: the host's regex extension

Expected differences: `toml.jl`'s last line (a long integer literal parses as a `BigInt` natively, an overflow error
in Wasm; see the README's *Differences*).
