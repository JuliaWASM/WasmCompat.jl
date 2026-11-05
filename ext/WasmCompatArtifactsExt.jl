"""
    WasmCompatArtifactsExt

Artifacts for WasmCodegen's closed world. One overlay (a method of
`WasmCodegen.Runtime.WASM_METHODS`, used only when compiling to Wasm):

- `Artifacts.parse_mapping` of a table (an `Overrides.toml` UUID entry; `load_overrides` runs on
  every `artifact_exists`/`artifact_path` lookup). The stdlib builds the `Dict` from a generator of
  `k => parse_mapping(v, ...)` pairs: each `v` is an `Any` (a dynamic call), and the generator's
  element type is the abstract `Pair{String}`, which WasmCodegen does not represent. Here the
  table is filled in a loop and each value's method is chosen by `isa`: the same methods, the
  same values, the same `Dict{String, Any}`.
"""
module WasmCompatArtifactsExt

import Artifacts
import WasmCodegen

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Artifacts.parse_mapping(
        mapping::Dict{String, Any}, name::String, override_file::String)
    d = Dict{String, Any}()
    for (k, v) in mapping
        d[k] = v isa String ? Artifacts.parse_mapping(v, name, override_file) :
               v isa Dict{String, Any} ? Artifacts.parse_mapping(v, name, override_file) :
               nothing # (`parse_mapping(mapping, name, override_file) = nothing`, the stdlib's fallthrough)
    end
    return d
end

end # module
