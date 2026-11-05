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
| `WasmCompatPCRE2Ext` | PCRE2_wasm_jll | Base's `Regex` on PCRE2 itself, compiled to WebAssembly: see *Regex* below. Opt-in, through `WasmCompat.pcre2_config`. | Needs WasmCodegen's `Config(foreign_functions)` and `Config(import_libraries)` |

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

## Regex

Base's `Regex` calls PCRE2, a C library a WebAssembly module does not have. With `WasmCompatPCRE2Ext`, those
calls (`pcre2_compile_8`, `pcre2_match_8`, ...) are Julia functions of the extension, over PCRE2 itself compiled to
WebAssembly as a separate module: [PCRE2_wasm_jll](https://github.com/pankgeorg/PCRE2_wasm_jll.jl)'s
`libpcre2-8.wasm`, which imports nothing. Base's `regex.jl` and `pcre.jl` run unchanged, so patterns, errors and
offsets are PCRE2's own. Unlike the other extensions, this one is opt-in, because the host must provide the module:

```julia
using WasmCodegen, WasmCompat, PCRE2_wasm_jll    # PCRE2_wasm_jll: the PCRE2 of the compiling Julia (10.46 for 1.13.2)
config = WasmCompat.pcre2_config(WasmCodegen.Config(host = :wasi))
WasmCodegen.compile([WasmCodegen.Entry(Program.main, (); name = "main")]; config)
cp(WasmCompat.pcre2_module(), "libpcre2-8.wasm")   # deploy it with the program
```

`pcre2_config` adds the extension's functions (`Config(foreign_functions)`, library `"libpcre2-8"`) and the import
library `"pcre2"` (`Config(import_libraries)`). The host instantiates the PCRE2 module, once per instance of the
program, and gives its exports as the import module `"pcre2"`; `js/pcre2.mjs` does that for JavaScript:

```js
import { pcre2Imports } from './pcre2.mjs';
const imports = { ...wasi.getImportObject(), ...(await pcre2Imports(fs.readFileSync('libpcre2-8.wasm'))) };
```

The program copies patterns and subjects into the PCRE2 module's memory and copies results back. What Base holds
(compiled patterns, match data) are Julia objects, and the ovector and name table it reads are Julia arrays.

- **No JIT.** Base compiles every pattern with `PCRE2_MATCH_INVALID_UTF`, and without a JIT PCRE2 then checks the
  subject's UTF-8 on every match, so `eachmatch` would be quadratic. A subject is checked once when it is copied in,
  and a valid one is matched with a twin of the pattern compiled without that option. `\C` in UTF mode is refused
  at `jit_compile`, as the native JIT does, so Base throws the same error.
- **Compiled patterns are kept** by pattern and options, because finalizers do not run in a module and `Regex`
  frees its pattern only in one. A program that builds the same pattern repeatedly compiles it once.
- **Size:** the PCRE2 module is 399 KB, 110 KB gzipped (PCRE2's whole 8-bit API; about 140 KB of it is Unicode
  tables). The program itself is no larger than with a host regex engine: the same regex workloads compile to
  43 KB (15 KB gzipped), against 44 KB with the host-RegExp engine of gbaraldi/WasmCodegen.jl#35.
- **Speed** (Node 24, best of 5): about 5× native Julia (with its JIT) per match, about 12× on engine-bound
  matching, and about native on compiling patterns.
- **Differs from native Julia:** an error PCRE2 detects only while matching can read differently, because the
  native JIT detects it as JIT stack exhaustion. Example: `(?R)` gives "nested recursion at the same subject
  position" here and "JIT stack limit reached" natively. PCRE2 without a JIT gives the same as here.

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
- **Tar's error messages** use a regex (`read_standard_header`), so programs that hit them need a
  regex engine: the PCRE2 extension (see *Regex*).

## Hosts

The extensions have no host side: they are Julia code compiled into the module, using only WASI
preview 1 through WasmCodegen's runtime. They are host-neutral, except that the PCRE2 extension needs the host to
instantiate PCRE2's module (`js/pcre2.mjs` for JavaScript; any host that can link two modules works the same).

| Host | Status |
|---|---|
| Node.js 24 (`node:wasi`) | **Tested**: `test/wasm/` compares each program's output with native Julia's |
| Browsers (a JS WASI shim) | Untested |
| Cloudflare workerd | Untested |
| wasmtime | Untested |

## Tests

- `test/runtests.jl` (native): the typed TOML printer against `TOML.print`, byte for byte, on fixed
  and random tables; the Wasm logger's records against `ConsoleLogger`'s; the regex-free version
  check against the regex; that every overlay is present; and the PCRE2 configuration, module and version.
- `test/wasm/` (needs Node 24): one small program per extension, compiled with `trim = :safe` and run
  on Node's WASI. `check.sh` diffs each program's output with native Julia's. With `PCRE2=1`, `regex.jl` (Base's
  Regex API, compile errors, PCRE-only constructs, Pkg's semver patterns on every `[compat]` range of the General
  registry, Tar's path checks) and `corpus.jl` (69 patterns through `eachmatch`, `keys` and `replace`) run on PCRE2.

## License

MIT. The overlays in `ext/TarExt` and `ext/ArgToolsExt`, and parts of the TOML and Logging
extensions, are derived from Julia's standard library (MIT, Copyright (c) 2009-2026: Jeff
Bezanson, Stefan Karpinski, Viral B. Shah, and other contributors).
