"""
    WasmCompatArgToolsExt

ArgTools for WasmCodegen's closed world. Overlays (methods of `WasmCodegen.Runtime.WASM_METHODS`,
used only when compiling to Wasm):

- **Callbacks specialized on.** `arg_read(f::Function, arg)`, `arg_write`, `arg_isdir`, `arg_mkdir`,
  `arg_readers` and `arg_writers` declare their callback `::Function` and pass it on, so Julia
  compiles them unspecialized and every call of the callback is dynamic. The overlays are the
  stdlib's own definitions with the callback a type parameter (`f::F where {F<:Function}`, the same
  signature), generated from the stdlib's sources by `gen/specialize_callbacks.jl`
  (`ArgToolsExt/specialized_<version>.jl`). Upstream: JuliaIO/ArgTools.jl#46.
- `arg_read(f, ::AbstractString)` and `arg_write(f, ::AbstractString)` call `open(f, path;
  lock = false)` directly, where the stdlib goes through `open_nolock(args...; kws...)`, whose
  splat of a callback is another dynamic call.
"""
module WasmCompatArgToolsExt

import ArgTools
import WasmCodegen

const GENERATED = joinpath(@__DIR__, "ArgToolsExt", "specialized_$(pkgversion(ArgTools)).jl")
if isfile(GENERATED)
    include(GENERATED)
    Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS ArgTools.arg_read(f::F, arg::AbstractString) where {F <: Function} =
        open(f, arg; lock = false)
    Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function ArgTools.arg_write(f::F, arg::AbstractString) where {F <: Function}
        try open(f, arg; write = true, lock = false)
        catch
            rm(arg, force = true)
            rethrow()
        end
        return arg
    end
else
    @warn "WasmCompat: no overlays for ArgTools $(pkgversion(ArgTools)) (generate them with gen/specialize_callbacks.jl)"
end

end # module
