# julia --project=env build.jl PROG.jl OUT.wasm   compile PROG.jl's `Prog.main` for WASI with WasmCodegen.
# ENV: COMPAT=0 builds without WasmCompat loaded; TRIM (safe), VERIFY (warn), EXT (comma-separated host extensions);
# PCRE2=1 builds with Base's Regex on PCRE2 (`WasmCompat.pcre2_config`), and copies the PCRE2 module next to OUT.wasm
using WasmCodegen, TOML, Logging, Tar, ArgTools, Artifacts, Dates
compat = get(ENV, "COMPAT", "1") == "1"
pcre2 = get(ENV, "PCRE2", "0") == "1"
pcre2 && @eval using PCRE2_wasm_jll
compat && @eval using WasmCompat
if compat
    for e in (:WasmCompatCoreExt, :WasmCompatTOMLExt, :WasmCompatLoggingExt, :WasmCompatTarExt, :WasmCompatArgToolsExt, :WasmCompatArtifactsExt,
              :WasmCompatPCRE2Ext)
        println("extension ", e, ": ", Base.get_extension(WasmCompat, e) !== nothing)
    end
end
include(abspath(ARGS[1]))
trim = Symbol(get(ENV, "TRIM", "safe")); verify = Symbol(get(ENV, "VERIFY", "warn"))
exts = Symbol[Symbol(x) for x in split(get(ENV, "EXT", ""), ',') if !isempty(x)]
cfg = WasmCodegen.Config(; host = :wasi, host_extensions = exts, trim, verify, on_unsupported = trim === :safe ? :error : :trap)
if pcre2
    cfg = WasmCompat.pcre2_config(cfg)
    cp(WasmCompat.pcre2_module(), joinpath(dirname(abspath(ARGS[2])), "libpcre2-8.wasm"); force = true)
end
t = time()
c = try
    WasmCodegen.compile([WasmCodegen.Entry(Prog.main, (); name = "main")]; config = cfg)
catch err
    println("COMPILE FAILED after ", round(time() - t; digits = 1), " s:")
    showerror(stdout, err); println(); exit(2)
end
println("compiled in ", round(time() - t; digits = 1), " s, ", length(c.bytes), " bytes, ", length(c.cgm.diagnostics), " diagnostics")
for (mi, u) in c.cgm.diagnostics
    println("  DIAG ", mi, ": ", first(sprint(show, u), 600))
end
rep = isassigned(c.world.trim_report) ? c.world.trim_report[] : ""
println("verifier: ", isempty(rep) ? "clean" : string(count("\nError", "\n" * rep) + count("\nWarning", "\n" * rep), " entries"))
isempty(rep) || write(ARGS[2] * ".verifier.txt", rep)
write(ARGS[2], c.bytes)
