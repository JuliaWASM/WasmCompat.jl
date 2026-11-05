"""
    WasmCompat

Compatibility of Julia's standard library with WasmCodegen's closed world. The package has no code
of its own that a program calls: each standard library it covers has a package extension, loaded
when the program loads that library and WasmCodegen together, which adds methods to WasmCodegen's
overlay method table (`WasmCodegen.Runtime.WASM_METHODS`). Those methods replace the library's
own only when WasmCodegen compiles a program; native code is unchanged.

| Extension | Loaded with | What it replaces in Wasm |
|---|---|---|
| `WasmCompatTOMLExt` | TOML | `TOML.print` with static dispatch; long integer literals without GMP |
| `WasmCompatLoggingExt` | Logging | `@info`/`@warn`/`@error` printed as `ConsoleLogger` prints them, to stderr |
| `WasmCompatTarExt` | Tar | callbacks specialized on; version field check without a regex |
| `WasmCompatArgToolsExt` | ArgTools | callbacks specialized on; `open` without a keyword splat |
| `WasmCompatArtifactsExt` | Artifacts | `Overrides.toml` tables parsed without an abstract `Pair` generator |

One function here is part of the extensions' interface with programs: [`showerror_hook`](@ref).

An overlay replaces the native method only where inference does not evaluate the call at compile
time: WasmCodegen's inference still evaluates calls with constant arguments using the native
methods (see `WasmCodegen.Runtime.@wasm_method`), so each overlay here reads state or performs
I/O rather than computing a constant.
"""
module WasmCompat

"""
    WasmCompat.showerror_hook(io::IO, e) -> Bool

Called in Wasm by the extensions that show exceptions of types not known at compile time (a
logged `exception = err` of a `catch`), before WasmCodegen's own `Runtime.showerror_any`, which
shows Base's exceptions. The default shows nothing and returns `false`. A program with exception
types of its own overlays it, typically with an `isa` test per type:

```julia
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function WasmCompat.showerror_hook(io::IO, @nospecialize(e))
    e isa MyError && (showerror(io, e::MyError); return true)
    return false
end
```
"""
showerror_hook(io::IO, @nospecialize(e)) = false

end # module
