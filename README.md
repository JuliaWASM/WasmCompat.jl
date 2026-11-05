# WasmCompat.jl

Julia's standard library for [WasmCodegen.jl](https://github.com/gbaraldi/WasmCodegen.jl)'s closed world.

WasmCodegen compiles a Julia program to WebAssembly (Wasm GC) the way `juliac --trim` compiles it
natively: every call must be resolvable at compile time. Some standard library code is not, either
because it relies on dynamic dispatch that a trimmed program cannot compile, or because it needs
something a Wasm module does not have, such as GMP or a regex engine. WasmCompat replaces that code,
only when WasmCodegen compiles a program, with code that is.

**WasmCompat has no API you call.** Load it in the build script, next to the standard libraries the
program uses, and compile as usual:

```julia
using WasmCodegen, WasmCompat
using TOML, Logging, Tar          # the program's standard libraries
include("program.jl")
WasmCodegen.compile([WasmCodegen.Entry(Program.main, (); name = "main")];
                    config = WasmCodegen.Config(host = :wasi, trim = :safe))
```

Each covered standard library has a package extension, loaded when the program loads that library
together with WasmCodegen. The extension adds methods to WasmCodegen's overlay method table
(`WasmCodegen.Runtime.WASM_METHODS`). WasmCodegen compiles those methods in place of the library's
own. **Native code is unchanged:** the same session can run the program natively, with the
standard library's own methods.

## Extensions

| Extension | Loaded with | In Wasm | Upstream |
|---|---|---|---|
| `WasmCompatTOMLExt` | TOML | `TOML.print` with static dispatch: each value is told apart by `isa`, then printed by Base's own `printvalue` methods, so the output is byte-identical. Integer literals too long for `Int128`/`UInt128` are a parse error rather than a `BigInt` (see *Differences*). | The printer's dynamic dispatch also fails `juliac --trim=safe` natively. |
| `WasmCompatLoggingExt` | Logging | `@info`, `@warn` and `@error` print what Base's default `ConsoleLogger(stderr)` prints for a stream without color. Without this, juliac's trim patches make every log call print nothing. | juliac's `current_logger_for_env` stub drops logs natively too. |
| `WasmCompatTarExt` | Tar | Callbacks (`predicate`, `callback`, `emit`) specialized on, so calling them is static. `check_version_field` without a regex. | JuliaIO/Tar.jl#206 (the same specializations) |
| `WasmCompatArgToolsExt` | ArgTools | Callbacks specialized on. `arg_read`/`arg_write` of a path call `open` without a keyword splat. | JuliaIO/ArgTools.jl#46 |
| `WasmCompatArtifactsExt` | Artifacts | `Overrides.toml` tables parsed in a loop, without a generator whose element type is the abstract `Pair{String}`. | |

The Tar and ArgTools overlays are the libraries' own definitions with `::Function` arguments made type
parameters. `gen/specialize_callbacks.jl` generates them from the installed Julia's stdlib sources,
one file per library version (`ext/TarExt/specialized_<version>.jl`). It checks that the printed code
parses back to the same definitions. For a Tar or ArgTools version without a generated file, the
extension warns and adds nothing.

### Interface for programs

`WasmCompat.showerror_hook(io, e) -> Bool` is called in Wasm before WasmCodegen's own
`Runtime.showerror_any`, for a logged exception whose type is not known at compile time
(`exception = err` in a `catch`). By default it does nothing. A program with exception types of its
own overlays it:

```julia
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function WasmCompat.showerror_hook(io::IO, @nospecialize(e))
    e isa MyError && (showerror(io, e::MyError); return true)
    return false
end
```

## Differences from native, by design

- **TOML:** an integer literal longer than 33 decimal digits (hex 34, octal 45, binary 130) is
  `ErrOverflowError`, as in a TOML parser limited to 64 bits. Natively it parses as a `BigInt`. A Wasm
  module has no GMP.
- **TOML:** inside an `Any`-typed container, a value must be of one of the types listed in
  `WasmCompatTOMLExt.SCALAR_TYPES`, `TABLE_TYPES` or `ARRAY_TYPES` (the parser's own output and the
  common concrete containers), or one of `UUID`, `SHA1`, `VersionNumber`, `Nothing` or `Symbol`
  passed through the conversion function. Any other value is an error in Wasm.
- **Logging:** the logger is fixed. `with_logger` and `global_logger` are not consulted, the
  minimum level is `Info`, and `JULIA_DEBUG` is ignored. Exceptions are shown without backtraces.
  Values are shown if they are of a common type (strings, symbols, numbers, versions, UUIDs) or an
  exception; any other value, vectors included, is shown as `(a value of type T)`.
- **Logging, a code-generator limit:** a log call whose key-value pairs include a value of a type
  not known at compile time builds a tuple of abstract type in the caller. An example is a caught
  `err` passed as it is: `@warn "..." exception = err`. WasmCodegen doesn't compile such a tuple
  (`trim = :safe` reports "a tuple of abstract type Tuple{Any}"), although native trim does. Assert
  the type at the call (`exception = err::MyError`) or pass a value of a concrete type.

## Requirements and known limits

- **Julia 1.13** (tested with 1.13.2). Julia 1.12 loads the package, but its overlays are untested there.
- **WasmCodegen with `WASM_METHODS`.** `WASM_METHODS` and `@wasm_method` are internal to WasmCodegen
  today. Asking the maintainer to make them a supported interface for packages is part of the
  `Config(import_libraries)` discussion upstream.
- **`verify = :error` does not pass yet.** WasmCodegen's juliac-equivalent verifier infers the
  program with the native method tables, so it reports the standard library's original code as
  unresolved even though the module contains the overlay instead. Build with `verify = :warn`.
  A generic fix in WasmCodegen is under discussion. Code generation is unaffected: `trim = :safe`
  reports 0 diagnostics.
- **Overlays must not be constant.** WasmCodegen's inference still evaluates calls with constant
  arguments using the native methods (see `WasmCodegen.Runtime.@wasm_method`). Each overlay here
  therefore reads state or performs I/O. For example, the Logging extension reads its logger from a
  global rather than constructing it.
- **`Tar.list` traps at run time** in a standalone test program on WasmCodegen r2 (a null dereference after `Tar.create` succeeds), and the cause is not yet known. `Tar.extract`, `read_tarball` and `tree_hash`, as a package manager uses them, run correctly in a full program on the same stack.
- **Tar's error messages** use a regex (`read_standard_header`), so programs that hit them need the
  host's regex extension (`Config(host_extensions = [:julia_regex])`).

## Hosts

The extensions have no host side: they are Julia code compiled into the module, using only WASI
preview 1 through WasmCodegen's runtime. They are host-neutral.

| Host | Status |
|---|---|
| Node.js 24 (`node:wasi`) | **Tested**: `test/wasm/` compares each program's output with native Julia's |
| Browsers (a JS WASI shim) | Untested |
| Cloudflare workerd | Untested |
| wasmtime | Untested |

## Tests

- `test/runtests.jl` (native): the typed TOML printer against `TOML.print`, byte for byte, on fixed
  and random tables; the Wasm logger's records against `ConsoleLogger`'s; the regex-free version
  check against the regex; and that every overlay is present.
- `test/wasm/` (needs Node 24): one small program per extension, compiled with `trim = :safe` and run
  on Node's WASI. `check.sh` diffs each program's output with native Julia's.

## License

MIT. The overlays in `ext/TarExt` and `ext/ArgToolsExt`, and parts of the TOML and Logging
extensions, are derived from Julia's standard library (MIT, Copyright (c) 2009-2026: Jeff
Bezanson, Stefan Karpinski, Viral B. Shah, and other contributors).
