"""
    WasmCompatTarExt

Tar for WasmCodegen's closed world. Overlays (methods of `WasmCodegen.Runtime.WASM_METHODS`, used
only when compiling to Wasm; native code is unchanged):

- **Callbacks specialized on.** Tar's API and internal functions take `predicate::Function`,
  `callback::Function` or `emit::Function` and pass them on without calling them, so Julia compiles
  them unspecialized and every call of the callback is dynamic. The overlays are Tar's own
  definitions with each such argument a type parameter (the same signature), generated from the
  stdlib's sources by `gen/specialize_callbacks.jl` (`TarExt/specialized_<version>.jl`).
  Upstream: JuliaIO/Tar.jl#206.
- `read_standard_header`'s message for a stream that is no tarball takes the error's message as
  the `String` it is (`err.msg::String`), where `String(err.msg)` is a dynamic call (also in #206).
- `check_version_field` without a regex: `occursin(r"^0* *\$", version)` on every header needs a
  regex engine, which a Wasm module only has with a host's regex extension. Here it is a loop over
  the field's bytes with the same result, PCRE's `\$` included (it also matches before one final
  newline).

Not here: `show(::IO, ::Tar.Header)` (Tar's error messages `repr` headers) needs `show(::IO,
::Symbol)` without Base's expression printer, which is a Base fix (JuliaLang/julia#64448, in Julia
1.14) and belongs in WasmCodegen's trim patches for older Julia versions.
"""
module WasmCompatTarExt

import Tar
import WasmCodegen

const GENERATED = joinpath(@__DIR__, "TarExt", "specialized_$(pkgversion(Tar)).jl")
if isfile(GENERATED)
    include(GENERATED)
else
    @warn "WasmCompat: no callback overlays for Tar $(pkgversion(Tar)) (generate them with gen/specialize_callbacks.jl)"
end

# `occursin(r"^0* *$", version)` of the version field (`read_header_str`: the bytes before the first NUL)
function version_field_ok(buf::AbstractVector{UInt8})
    r = Tar.index_range(:version)
    stop = last(r)
    for i in r
        if buf[i] == 0x00
            stop = i - 1
            break
        end
    end
    i = first(r)
    while i <= stop && buf[i] == 0x30 # '0'
        i += 1
    end
    while i <= stop && buf[i] == 0x20 # ' '
        i += 1
    end
    return i > stop || (i == stop && buf[i] == 0x0a) # (PCRE's `$` before a final newline)
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Tar.check_version_field(buf::AbstractVector{UInt8})
    version_field_ok(buf) && return
    version = Tar.read_header_str(buf, :version)
    Tar.header_error(buf, "invalid version string for tar file: $(repr(version))")
end

end # module
