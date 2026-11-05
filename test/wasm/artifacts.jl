# WasmCompatArtifactsExt: Artifacts.load_overrides of an Overrides.toml with hash and UUID entries
module Prog
import Artifacts
using Base: UUID, SHA1
out(xs...) = (for x in xs; write(Core.stdout, x); end; write(Core.stdout, "\n"))
function main()
    depot = joinpath(ENV["WORK"], "depot")
    mkpath(joinpath(depot, "artifacts"))
    write(joinpath(depot, "artifacts", "Overrides.toml"), """
    a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 = "/opt/override"
    [7876af07-990d-54b4-ab0e-23690620f79a]
    libfoo = "0123456789abcdef0123456789abcdef01234567"
    libbar = "/abs/path"
    """)
    empty!(DEPOT_PATH)
    push!(DEPOT_PATH, depot)
    ov = Artifacts.load_overrides(; force = true)
    for (k, v) in ov[:UUID]::Dict{UUID, Dict{String, Union{String, SHA1}}}
        for name in sort!(collect(keys(v)))
            x = v[name]
            out(string(k), " ", name, " => ", x isa SHA1 ? "SHA1 " * bytes2hex(x.bytes) : x isa String ? x : "?")
        end
    end
    for (k, v) in ov[:hash]::Dict{SHA1, Union{String, SHA1}}
        out("hash ", bytes2hex(k.bytes), " => ", v isa String ? v : "?")
    end
    return 0
end
end
