# julia --project=env build.jl PROG.jl OUT.wasm   compile PROG.jl's `Prog.main` for WASI with WasmCodegen.
# ENV: COMPAT=0 builds without WasmCompat loaded; TRIM (safe), VERIFY (warn), EXT (comma-separated host extensions);
# PCRE2=1 builds with Base's Regex on PCRE2 (`WasmCompat.pcre2_config`), and copies the PCRE2 module next to OUT.wasm;
# LIBGIT2=1 builds with LibGit2 on libgit2 (`WasmCompat.libgit2_config`), and copies the libgit2 module next to OUT.wasm
using WasmCodegen, TOML, Logging, Tar, ArgTools, Artifacts, Dates, MsgPack
compat = get(ENV, "COMPAT", "1") == "1"
pcre2 = get(ENV, "PCRE2", "0") == "1"
pcre2 && @eval using PCRE2_wasm_jll
libgit2 = get(ENV, "LIBGIT2", "0") == "1"
libgit2 && @eval using LibGit2, LibGit2_wasm_jll
compat && @eval using WasmCompat
if compat
    for e in (:WasmCompatTOMLExt, :WasmCompatLoggingExt, :WasmCompatTarExt, :WasmCompatArgToolsExt, :WasmCompatArtifactsExt, :WasmCompatMsgPackExt,
              :WasmCompatPCRE2Ext, :WasmCompatLibGit2Ext, :WasmCompatBaseExt, :WasmCompatSIMDExt)
        println("extension ", e, ": ", Base.get_extension(WasmCompat, e) !== nothing)
    end
end
# (the program is compiled with the ARGS of a program run with no arguments, which is how run.mjs and check.sh's
# native run start it: a compiled module has the ARGS of its build. The two paths are locals: a program may define
# a global of any name, and may change ARGS or the directory. OUT is made absolute by `joinpath`, which leaves a
# `link/..` to the filesystem where `abspath` would take it textually. `Prog` is of a world later than this block's,
# hence the `eval`.)
let prog = abspath(ARGS[1]), out = joinpath(pwd(), ARGS[2]), dir = dirname(out)
    empty!(ARGS)
    include(prog)
    trim = Symbol(get(ENV, "TRIM", "safe")); verify = Symbol(get(ENV, "VERIFY", "warn"))
    exts = Symbol[Symbol(x) for x in split(get(ENV, "EXT", ""), ',') if !isempty(x)]
    cfg = WasmCodegen.Config(; host = :wasi, host_extensions = exts, trim, verify, on_unsupported = trim === :safe ? :error : :trap)
    if pcre2
        cfg = WasmCompat.pcre2_config(cfg)
        cp(WasmCompat.pcre2_module(), joinpath(dir, "libpcre2-8.wasm"); force = true)
    end
    if libgit2
        cfg = WasmCompat.libgit2_config(cfg)
        cp(WasmCompat.libgit2_module(), joinpath(dir, "libgit2.wasm"); force = true)
    end
    # (tests run on optimized modules only: wasm-opt -O3, WasmCodegen's default)
    cfg.optimize === nothing && error("build.jl: Config(optimize = nothing): the checks run on modules optimized by wasm-opt only")
    println("optimize: wasm-opt ", join(cfg.optimize.exec, ' '))
    t = time()
    c = try
        WasmCodegen.compile([WasmCodegen.Entry(Core.eval(Main, :(Prog.main)), (); name = "main")]; config = cfg)
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
    isempty(rep) || write(out * ".verifier.txt", rep)
    write(out, c.bytes)
end
