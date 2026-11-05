# WasmCompatTOMLExt: TOML.parse and TOML.print (sorted, unsorted, inline tables, `by`, a conversion
# function, arrays of tables, dates) of the kinds of tables package managers write
module Prog
import TOML, Dates
using Base: UUID
out(s) = write(Core.stdout, s)
function main()
    doc = """
    name = "Example"
    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
    version = "0.5.4"
    authors = ["A <a@example.com>", "B"]
    [deps]
    Alpha = "11111111-2222-3333-4444-555555555555"
    "needs quotes" = "x"
    [compat]
    julia = "1.6"
    [[arr]]
    x = 1
    [[arr]]
    x = 2.5
    y = [true, false]
    z = 0x7f
    [nested.inner]
    when = 1979-05-27T07:32:00Z
    day = 1979-05-27
    at = 07:32:00
    s = "line\\nbreak \\"q\\" \\u00e9"
    big = 12345678901234567890123
    """
    d = TOML.parse(doc)
    io = IOBuffer()
    TOML.print(io, d; sorted = true)
    out(String(take!(io)))
    out("---- unsorted\n")
    TOML.print(io, d)
    out(String(take!(io)))
    out("---- project\n")
    # (built by assignment: `Dict{String, Any}(pairs of mixed types...)` is a separate WasmCodegen case)
    p = Dict{String, Any}()
    p["name"] = "X"; p["uuid"] = UUID("7876af07-990d-54b4-ab0e-23690620f79a"); p["version"] = v"1.2.3"
    deps = Dict{String, Any}(); deps["B"] = "b"; deps["A"] = "a"; p["deps"] = deps
    srcB = Dict{String, Any}(); srcB["url"] = "https://example.com/B.jl"; srcB["rev"] = "main"
    sources = Dict{String, Any}(); sources["B"] = srcB; p["sources"] = sources
    p["extras"] = Dict{String, String}("T" => "t"); targets = Dict{String, Any}(); targets["test"] = ["T"]; p["targets"] = targets
    inline = Base.IdSet{Dict}()
    push!(inline, srcB)
    order = Dict("name" => 0, "uuid" => 1, "version" => 2)
    TOML.print(io, p; inline_tables = inline, sorted = true, by = k -> (get(order, k, 9), k)) do x
        x isa UUID || x isa VersionNumber || error("unhandled type")
        return string(x)
    end
    out(String(take!(io)))
    out("---- manifest-like\n")
    m = Dict{String, Any}()
    m["julia_version"] = "1.13.2"; m["manifest_format"] = "2.0"
    e = Dict{String, Any}(); e["uuid"] = "u"; e["version"] = "1.0.0"; e["deps"] = ["B", "C"]; e["git-tree-sha1"] = "abc"
    m["deps"] = Dict{String, Vector{Dict{String, Any}}}("A" => [e])
    m["usage"] = Dict{String, Vector{Dict{String, Dates.DateTime}}}("/x" => [Dict("time" => Dates.DateTime(2026, 11, 5, 12, 30, 1, 5))])
    TOML.print(io, m; sorted = true)
    out(String(take!(io)))
    out("---- long integer (a documented divergence: BigInt natively, an overflow error in Wasm)\n")
    r = TOML.tryparse("big = 123456789012345678901234567890123456789")
    out(r isa TOML.ParserError ? "ParserError\n" : "parsed\n")
    return 0
end
end
