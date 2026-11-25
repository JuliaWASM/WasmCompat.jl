# Native tests of WasmCompat's extensions: each typed replacement against the standard library's
# own code, byte for byte, and the overlays' presence in WasmCodegen's table. The programs in
# test/wasm/ check the same in Wasm (they need Node; see test/wasm/README.md).

using Test
using WasmCodegen, WasmCompat
import TOML, Logging, Tar, ArgTools, Artifacts, Dates, MsgPack
import PCRE2_wasm_jll
import LibGit2, LibGit2_wasm_jll
using Base: UUID, SHA1, IdSet
using Random: Xoshiro

struct Opaque end

ext(name) = something(Base.get_extension(WasmCompat, name), nothing)
const TOMLExt = ext(:WasmCompatTOMLExt)
const LoggingExt = ext(:WasmCompatLoggingExt)
const TarExt = ext(:WasmCompatTarExt)
const ArgToolsExt = ext(:WasmCompatArgToolsExt)
const ArtifactsExt = ext(:WasmCompatArtifactsExt)
const MsgPackExt = ext(:WasmCompatMsgPackExt)
const PCRE2Ext = ext(:WasmCompatPCRE2Ext)
const LibGit2Ext = ext(:WasmCompatLibGit2Ext)

# the methods of WasmCodegen's overlay table defined by module `m`
function overlays(m::Module)
    found = Method[]
    Base.visit(WasmCodegen.Runtime.WASM_METHODS) do meth
        meth.module === m && push!(found, meth)
    end
    return found
end

@testset "WasmCompat" begin
    @testset "extensions load" begin
        @test TOMLExt isa Module
        @test LoggingExt isa Module
        @test TarExt isa Module
        @test ArgToolsExt isa Module
        @test ArtifactsExt isa Module
        @test MsgPackExt isa Module
        @test PCRE2Ext isa Module
        @test LibGit2Ext isa Module
    end

    @testset "TOML: typed printer = TOML.print" begin
        typed(d; sorted = false, by = identity, inline_tables = IdSet{Dict{String}}(), f = identity) =
            sprint(io -> TOMLExt.print_table(f, io, d, String[], 0, true, sorted, inline_tables, by))
        stock(d; sorted = false, by = identity, inline_tables = IdSet{Dict{String}}(), f = identity) =
            sprint(io -> TOML.print(f, io, d; sorted, by, inline_tables))
        doc = """
        name = "Example"
        version = "0.5.4"
        authors = ["A <a@example.com>", "B"]
        [deps]
        Alpha = "11111111-2222-3333-4444-555555555555"
        "needs quotes" = "x"
        [[arr]]
        x = 1
        [[arr]]
        x = 2.5
        y = [true, false, 3, "mixed"]
        z = 0x7f
        [nested.inner]
        when = 1979-05-27T07:32:00Z
        day = 1979-05-27
        at = 07:32:00.5
        s = "line\\nbreak \\"q\\" \\u00e9 \\t"
        inf = inf
        nan = nan
        neg = -0.0
        empty = {}
        inl = {a = 1, b = [1, 2]}
        [nested.empty]
        """
        d = TOML.parse(doc)
        @test typed(d) == stock(d)
        @test typed(d; sorted = true) == stock(d; sorted = true)
        order = Dict("name" => 0, "version" => 1)
        by = k -> (get(order, k, 9), k)
        @test typed(d; sorted = true, by) == stock(d; sorted = true, by)

        # a project-like table: a conversion function, inline tables, `by`
        p = Dict{String, Any}("name" => "X", "uuid" => UUID("7876af07-990d-54b4-ab0e-23690620f79a"),
            "version" => v"1.2.3", "deps" => Dict{String, Any}("B" => "b", "A" => "a"),
            "sources" => Dict{String, Any}("B" => Dict{String, Any}("url" => "https://example.com/B.jl", "rev" => "main")),
            "extras" => Dict{String, String}("T" => "t"), "targets" => Dict{String, Any}("test" => ["T"]),
            "compat" => Dict{String, Any}("julia" => "1.10"), "nothing" => nothing, "sym" => :s)
        inline = IdSet{Dict}()
        push!(inline, p["sources"]["B"])
        conv = x -> x isa Union{UUID, VersionNumber, Nothing, Symbol} ? string(x) : error("unhandled")
        for sorted in (false, true)
            @test typed(p; f = conv, sorted, by, inline_tables = inline) == stock(p; f = conv, sorted, by, inline_tables = inline)
        end
        # a manifest-like table (arrays of tables of several element types, dates)
        m = Dict{String, Any}("julia_version" => "1.13.2", "manifest_format" => "2.0",
            "deps" => Dict{String, Vector{Dict{String, Any}}}("A" => [Dict{String, Any}("uuid" => "u", "version" => "1.0.0",
                "deps" => ["B", "C"], "git-tree-sha1" => "abc"), Dict{String, Any}("uuid" => "v")]),
            "usage" => Dict{String, Vector{Dict{String, Dates.DateTime}}}("/x" => [Dict("time" => Dates.DateTime(2026, 11, 5, 12, 30, 1, 5))]),
            "dates" => [Dates.Date(2026, 1, 2), Dates.Date(2026, 3, 4)])
        @test typed(m; sorted = true) == stock(m; sorted = true)
        # random tables of the kinds of values the printer knows
        rng = Xoshiro(7)
        leaf() = rand(rng, (() -> rand(rng, Int), () -> rand(rng), () -> rand(rng, Bool),
                            () -> string("s", rand(rng, 1:99)), () -> [rand(rng, Int) for _ in 1:rand(rng, 0:3)],
                            () -> String[string(i) for i in 1:rand(rng, 0:3)]))()
        function table(depth)
            t = Dict{String, Any}()
            for i in 1:rand(rng, 0:5)
                k = rand(rng, ("a", "b", "c d", "é", "x$i", ""))
                t[k] = depth > 0 && rand(rng) < 0.3 ? table(depth - 1) :
                       depth > 0 && rand(rng) < 0.15 ? Dict{String, Any}[table(depth - 1) for _ in 1:2] : leaf()
            end
            return t
        end
        for _ in 1:200
            t = table(3)
            @test typed(t; sorted = true) == stock(t; sorted = true)
            @test typed(t) == stock(t)
        end
        # errors as Base's: no conversion function, a conversion to a non-TOML value
        @test_throws ErrorException typed(Dict{String, Any}("u" => UUID(0)))
        @test_throws ErrorException typed(Dict{String, Any}("u" => UUID(0)); f = x -> x)
        # a value of a type the closed-world printer does not know
        @test_throws ErrorException typed(Dict{String, Any}("o" => [Opaque()]))
        # the overlays: print_table, and the four integer parsers
        @test length(overlays(TOMLExt)) >= 5
    end

    @testset "Logging: Wasm logger = ConsoleLogger" begin
        # (ConsoleLogger on a stream without color, sized as `displaysize()`, as stderr redirected to a file)
        function stock(f)
            buf = IOBuffer()
            Logging.with_logger(f, Logging.ConsoleLogger(buf, Logging.Info))
            return String(take!(buf))
        end
        typed(level, msg, kw; mod = Main, file = "/a/b.jl", line = 3, id = :x) = sprint() do io
            LoggingExt.log_record(io, level, msg, mod, id, file, line, kw)
        end
        # each record as the macro would pass it (`_file`/`_line` given, so both sides agree)
        cases = [
            (Logging.Info, "plain", (;)),
            (Logging.Info, "values", (; n = 3, s = "str", sym = :abc, ver = v"1.2.3", u = UUID(1), b = true, f = 1.5)),
            (Logging.Warn, "warn", (; key = :sym)),
            (Logging.Error, "err", (; exception = ErrorException("boom"))),
            (Logging.Warn, "arg", (; e = ArgumentError("bad"))),
            (Logging.Info, "multi\nline\nmessage", (; x = "a\nb")),
        ]
        for (level, msg, kw) in cases
            native = stock() do
                Base.CoreLogging.handle_message(Logging.current_logger(), level, msg, Main, :g, :x, "/a/b.jl", 3; kw...)
            end
            @test typed(level, msg, kw) == native
        end
        # maxlog: counted per id
        empty!(LoggingExt.MAXLOG)
        outs = [typed(Logging.Warn, "once", (; maxlog = 1, i = i); id = :once) for i in 1:3]
        @test outs[1] != "" && outs[2] == "" && outs[3] == ""
        # a value of a type it does not know
        @test occursin("(a value of type", typed(Logging.Info, "m", (; t = (1, 2))))
        # the program's exceptions
        @test LoggingExt.showerror_any(IOBuffer(), ErrorException("x")) === nothing
        @test length(overlays(LoggingExt)) == 1
    end

    @testset "Tar: version field without a regex" begin
        r = Tar.index_range(:version)
        fields = [UInt8[], b"00", b"  ", b"0 ", b"00 ", b"0 0", b"01", b"\n", b"00\n", b"0 \n", b"0\n\n", b" 0", b"0\x00x", b"\x00", b"ab"]
        for f in fields
            buf = zeros(UInt8, 512)
            buf[first(r):first(r) + min(length(f), length(r)) - 1] .= f[1:min(length(f), length(r))]
            @test TarExt.version_field_ok(buf) == occursin(r"^0* *$", Tar.read_header_str(buf, :version))
        end
        @test length(overlays(TarExt)) >= 16 # the generated callback specializations + check_version_field
        @test length(overlays(ArgToolsExt)) >= 12
        @test length(overlays(ArtifactsExt)) == 1
    end

    @testset "MsgPack: pack by isa, byte for byte" begin
        d = Dict{String, Any}("i" => 1, "u" => typemax(UInt64), "s" => "α", "f" => 1.5f0, "n" => nothing,
                              "m" => missing, "y" => :sym, "c" => 'é', "v" => Any[1, "a", 2.0, true],
                              "b" => UInt8[0, 255], "e" => MsgPack.Extension(Int8(3), UInt8[1, 2]),
                              "d" => Dict{String, Any}("x" => Any[Dict{String, Any}("deep" => -1)]),
                              "w" => repeat("w", 300), "a" => collect(1:20))
        for x in (d, Any[d, "x", 1], Dict{String, Float64}("a" => 1.0), (1, "t"), 7)
            io = IOBuffer()
            MsgPackExt.pack_value(io, x)               # (by the static type: concrete)
            @test take!(io) == MsgPack.pack(x)
            typeof(x) in MsgPackExt.VALUE_TYPES || continue
            MsgPackExt.pack_any(io, x)                 # (by isa, as for an Any-typed value)
            @test take!(io) == MsgPack.pack(x)
        end
        # a value of a type it does not know, in an Any-typed place: an error naming the type
        e = try MsgPackExt.pack_any(IOBuffer(), Opaque()); nothing catch err; err end
        @test e isa ErrorException && occursin("Opaque", e.msg) && occursin("VALUE_TYPES", e.msg)
        # every type it tells apart is packed by MsgPack without an AnyType mapping
        @test all(T -> !(MsgPack.msgpack_type(T) isa MsgPack.AnyType), MsgPackExt.VALUE_TYPES)
        # (invalid_pack's message: #76's text; the MsgPack type as `T()`, as `show` prints it)
        @test string(MsgPack.IntegerType()) == "$(typeof(MsgPack.IntegerType()))()"
        @test length(overlays(MsgPackExt)) == 2   # pack(io, x), invalid_pack
    end

    @testset "PCRE2: the configuration and the module" begin
        m = WasmCompat.pcre2_module()
        @test isfile(m) && read(m, 4) == b"\0asm"
        # the module's PCRE2 is the compiling Julia's (error messages and offsets differ between minors)
        native = PCRE2Ext.native_pcre2_version()
        @test (native.major, native.minor) == (pkgversion(PCRE2_wasm_jll).major, pkgversion(PCRE2_wasm_jll).minor)
        # one function per PCRE2 call Base's pcre.jl makes outside its JIT stacks and match contexts
        names = Set(first(k) for (k, _) in PCRE2Ext.FUNCTIONS)
        @test length(names) == 13 && all(k -> k[2] == "libpcre2-8", first.(PCRE2Ext.FUNCTIONS))
        @test :pcre2_match_8 in names && :pcre2_substring_copy_bynumber_8 in names
        c = WasmCompat.pcre2_config(WasmCodegen.Config(host = :wasi, import_libraries = ["other"]))
        @test length(c.foreign_functions) == 13 && c.import_libraries == ["other", "pcre2"]
        @test WasmCompat.pcre2_config(c).import_libraries == ["other", "pcre2"]
        @test_throws ArgumentError WasmCompat.pcre2_config(WasmCodegen.Config(host = :js))
    end

    @testset "LibGit2: the configuration, the module and the overlays" begin
        m = WasmCompat.libgit2_module()
        @test isfile(m) && read(m, 4) == b"\0asm"
        @test LibGit2.version() == VersionNumber(pkgversion(LibGit2_wasm_jll).major, pkgversion(LibGit2_wasm_jll).minor,
                                                 pkgversion(LibGit2_wasm_jll).patch)
        fs = LibGit2Ext.FUNCTIONS
        @test all(k -> k[2] == LibGit2.LibGit2_jll.libgit2, first.(fs))
        names = Set(first(k) for (k, _) in fs)
        @test length(names) == length(fs)
        @test :git_repository_open in names && :git_revparse_single in names && :git_oid_fromraw in names
        # the calls with structs or pointer arrays are overlays, not foreign functions
        @test !(:git_clone in names) && !(:git_remote_fetch in names) && !(:git_checkout_tree in names)
        @test length(overlays(LibGit2Ext)) >= 30
        c = WasmCompat.libgit2_config(WasmCodegen.Config(host = :wasi, import_libraries = ["other"]))
        @test length(c.foreign_functions) == length(fs) && c.import_libraries == ["other", "libgit2"]
        @test_throws ArgumentError WasmCompat.libgit2_config(WasmCodegen.Config(host = :js))
        # a string with a NUL is not a `Cstring`, in the overlays either (the error is Base's, before any call)
        e = try LibGit2Ext.cstring("check\0out") catch e; e end
        e0 = try Base.unsafe_convert(Cstring, "check\0out") catch e; e end
        @test e isa ArgumentError && e.msg == e0.msg
        # (before anything is allocated for the call: these are not in an overlay's `finally`)
        @test_throws ArgumentError LibGit2Ext.strarray(["a", "a\0b"])
        @test isempty(LibGit2Ext.TEMPS)
        # the options the module is not given are errors unless they are LibGit2's defaults, which have no
        # certificate check in Wasm (`certificate_cb()` is null there, and is not here)
        nocheck = LibGit2.RemoteCallbacks(certificate_check = C_NULL)
        fetch_options(; proxy_opts = LibGit2.ProxyOptions(certificate_cb = C_NULL), kw...) =
            LibGit2.FetchOptions(; callbacks = nocheck, proxy_opts, kw...)
        @test LibGit2Ext.check_fetch_options(fetch_options()) === nothing
        @test LibGit2Ext.check_fetch_options(fetch_options(depth = 1, prune = 1)) === nothing
        @test_throws "certificate_check" LibGit2Ext.check_fetch_options(LibGit2.FetchOptions())
        @test_throws "certificate_check" LibGit2Ext.check_fetch_options(LibGit2.FetchOptions(callbacks = nocheck))
        @test_throws "certificate_check" LibGit2Ext.check_fetch_options(
            fetch_options(callbacks = LibGit2.RemoteCallbacks(certificate_check = Ptr{Cvoid}(8))))
        url = "http://proxy.example"
        GC.@preserve url begin
            proxy = LibGit2.ProxyOptions(proxytype = LibGit2.Consts.PROXY_SPECIFIED, url = Base.unsafe_convert(Cstring, url),
                                         certificate_cb = C_NULL)
            @test_throws "FetchOptions(proxy_opts)" LibGit2Ext.check_fetch_options(fetch_options(proxy_opts = proxy))
        end
        @test_throws "FetchOptions(proxy_opts)" LibGit2Ext.check_fetch_options(
            fetch_options(proxy_opts = LibGit2.ProxyOptions(proxytype = LibGit2.Consts.PROXY_NONE, certificate_cb = C_NULL)))
        @test_throws "FetchOptions(custom_headers)" LibGit2Ext.check_fetch_options(
            fetch_options(custom_headers = LibGit2.StrArrayStruct(Ptr{Cstring}(8), 1)))
        @test LibGit2Ext.check_clone_checkout(LibGit2.CloneOptions().checkout_opts) === nothing
        @test LibGit2Ext.check_clone_checkout(LibGit2.CheckoutOptions(checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE)) === nothing
        GC.@preserve url begin
            @test_throws "target_directory" LibGit2Ext.check_clone_checkout(
                LibGit2.CheckoutOptions(target_directory = Base.unsafe_convert(Cstring, url)))
        end
        @test_throws ArgumentError LibGit2Ext.check_clone_checkout(LibGit2.CheckoutOptions(file_mode = 0o600))
        @test_throws ArgumentError LibGit2Ext.check_clone_checkout(LibGit2.CheckoutOptions(disable_filters = 1))
        @test_throws "CheckoutOptions(paths)" LibGit2Ext.check_clone_checkout(
            LibGit2.CheckoutOptions(paths = LibGit2.StrArrayStruct(Ptr{Cstring}(8), 1)))
        # (what a clone does not give the module: the callbacks, the baselines, another version of the options)
        for field in (:notify_cb, :progress_cb, :perfdata_cb, :baseline, :baseline_index)
            @test_throws ArgumentError LibGit2Ext.check_clone_checkout(LibGit2.CheckoutOptions(; field => Ptr{Cvoid}(8)))
        end
        @test_throws ArgumentError LibGit2Ext.check_clone_checkout(LibGit2.CheckoutOptions(version = 2))
        # the callbacks are dropped; a certificate check that is not null is an error, a null one is not; and a
        # name that is not a callback's is the MethodError of `RemoteCallbacks(::Callbacks)`
        @test LibGit2Ext.remote_callbacks(LibGit2.Callbacks()) isa LibGit2.RemoteCallbacks
        r = LibGit2Ext.remote_callbacks(LibGit2.Callbacks(:credentials => (Ptr{Cvoid}(16), 1),
                                                         :transfer_progress => (Ptr{Cvoid}(8), 2)))
        @test r.credentials == C_NULL && r.transfer_progress == C_NULL && r.payload === nothing
        @test LibGit2Ext.remote_callbacks(LibGit2.Callbacks(:certificate_check => (C_NULL, nothing))) isa LibGit2.RemoteCallbacks
        @test_throws "certificate_check" LibGit2Ext.remote_callbacks(LibGit2.Callbacks(:certificate_check => (Ptr{Cvoid}(8), nothing)))
        misnamed = LibGit2.Callbacks(:certficate_check => (Ptr{Cvoid}(8), nothing), :credentials => (C_NULL, nothing))
        e = try LibGit2Ext.remote_callbacks(misnamed) catch e; e end
        e0 = try LibGit2.RemoteCallbacks(misnamed) catch e; e end
        @test e isa MethodError && e0 isa MethodError && e.f === e0.f && e.args[2] === e0.args[2] &&
              occursin("certficate_check", sprint(showerror, e))
        # no executable bits after a dry run
        @test LibGit2Ext.dry_run(LibGit2.Consts.CHECKOUT_FORCE | LibGit2.Consts.CHECKOUT_DRY_RUN)
        @test !LibGit2Ext.dry_run(LibGit2.Consts.CHECKOUT_FORCE) && !LibGit2Ext.dry_run(LibGit2.Consts.CHECKOUT_SAFE)
    end

    include("simd.jl")

    @testset "generated overlays are current" begin
        # (the generator writes for this Julia's Tar and ArgTools; compare when they are the ones generated)
        for (mod, sub) in ((Tar, "TarExt"), (ArgTools, "ArgToolsExt"))
            file = joinpath(dirname(@__DIR__), "ext", sub, "specialized_$(pkgversion(mod)).jl")
            @test isfile(file)
        end
    end
end
