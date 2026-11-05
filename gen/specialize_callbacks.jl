# Generates the overlays of WasmCompat's Tar and ArgTools extensions from the stdlib sources of the
# running Julia:
#
#   julia --startup-file=no gen/specialize_callbacks.jl
#
# writes ext/TarExt/specialized_<Tar version>.jl and ext/ArgToolsExt/specialized_<ArgTools version>.jl.
#
# Each definition of the module with a positional argument declared `x::Function` is copied with
# that argument a type parameter (`x::WasmF1` with `WasmF1 <: Function`: the same signature, so
# the copy replaces the method in WasmCodegen's overlay table). Julia does not specialize on an
# argument declared `::Function` that a method only passes on, so in a closed world every call of
# such a callback is dynamic (see JuliaIO/Tar.jl#206, JuliaIO/ArgTools.jl#46). Bodies are unchanged
# but for the rewrites listed per module. The output is checked to parse back to the same code.

using Tar, ArgTools

const OVERLAY = :(Base.Experimental.var"@overlay")
const TABLE = :(WasmCodegen.Runtime.WASM_METHODS)

function specialize_callbacks(sig)
    params = Any[]
    call = sig
    while Meta.isexpr(call, :where)
        append!(params, call.args[2:end])
        call = call.args[1]
    end
    Meta.isexpr(call, :call) || return nothing
    args = copy(call.args)
    n = 0
    for i in 2:length(args)
        a = args[i]
        Meta.isexpr(a, :parameters) && continue
        target = Meta.isexpr(a, :kw) ? a.args[1] : a
        if Meta.isexpr(target, :(::)) && length(target.args) == 2 && target.args[2] === :Function
            n += 1
            F = Symbol("WasmF", n)
            typed = Expr(:(::), target.args[1], F)
            args[i] = Meta.isexpr(a, :kw) ? Expr(:kw, typed, a.args[2]) : typed
            push!(params, Expr(:(<:), F, :Function))
        end
    end
    n == 0 && return nothing
    return args[1], Expr(:where, Expr(:call, args...), params...)
end

# the method's function qualified with its module (`f` -> `Mod.f`); `Base.f` stays as it is
function qualified(sig, mod::Symbol)
    sig isa Expr || return sig
    if Meta.isexpr(sig, :where)
        return Expr(:where, qualified(sig.args[1], mod), sig.args[2:end]...)
    end
    @assert Meta.isexpr(sig, :call)
    f = sig.args[1]
    f isa Symbol || return sig
    return Expr(:call, Expr(:., mod, QuoteNode(f)), sig.args[2:end]...)
end

# (`name(...)` of a definition's signature)
function defname(sig)
    while Meta.isexpr(sig, :where); sig = sig.args[1]; end
    return Meta.isexpr(sig, :call) && sig.args[1] isa Symbol ? sig.args[1] : nothing
end

function definitions(file::String; also = Symbol[])
    defs = Tuple{Symbol, Expr, Int}[] # (name, definition, line)
    function visit(ex, line)
        if Meta.isexpr(ex, :module)
            body = ex.args[3].args
            l = line
            for x in body
                x isa LineNumberNode ? (l = x.line) : visit(x, l)
            end
        elseif Meta.isexpr(ex, :macrocall) && length(ex.args) >= 4 && ex.args[1] == GlobalRef(Core, Symbol("@doc"))
            visit(ex.args[end], line)
        elseif Meta.isexpr(ex, :function) || (Meta.isexpr(ex, :(=)) && Meta.isexpr(ex.args[1], (:call, :where)))
            r = specialize_callbacks(ex.args[1])
            if r !== nothing
                push!(defs, (r[1], Expr(:function, r[2], ex.args[2]), line))
            elseif defname(ex.args[1]) in also # (copied for a rewrite of its body only)
                push!(defs, (defname(ex.args[1]), Expr(:function, ex.args[1], ex.args[2]), line))
            end
        end
    end
    top = Meta.parseall(read(file, String); filename = file)
    l = 0
    for x in top.args
        x isa LineNumberNode ? (l = x.line) : visit(x, l)
    end
    return defs
end

strip_lines(ex) = Base.remove_linenums!(deepcopy(ex))

# the line of every macro call `f`ed (`remove_linenums!` keeps them): relative to the stdlib's
# source directory in the output (no local paths), `LineNumberNode(0)` to compare
function macro_lines!(f, ex)
    ex isa Expr || return ex
    if ex.head === :macrocall && length(ex.args) >= 2 && ex.args[2] isa LineNumberNode
        ex.args[2] = f(ex.args[2])
    end
    foreach(x -> macro_lines!(f, x), ex.args)
    return ex
end
# (and a block of one expression as that expression: printing drops some `begin ... end`s)
unblock(x) = x isa Expr ? (y = Expr(x.head, map(unblock, x.args)...); y.head === :block && length(y.args) == 1 ? y.args[1] : y) : x
normalized(ex) = unblock(macro_lines!(_ -> LineNumberNode(0), strip_lines(ex)))

# the first subexpressions where `a` and `b` differ (for the round-trip check's message)
function firstdiff(a, b)
    a == b && return nothing
    (a isa Expr && b isa Expr && a.head === b.head && length(a.args) == length(b.args)) || return (a, b)
    for (x, y) in zip(a.args, b.args)
        d = firstdiff(x, y)
        d === nothing || return d
    end
    return (a, b)
end

function generate(mod::Module, files, outfile; skip = Tuple{Symbol, String}[], rewrite = Dict{Symbol, Function}(),
        extra_imports = Symbol[], also = Symbol[], uses = Symbol[])
    m = nameof(mod)
    src = dirname(pathof(mod))
    # every name the module's code sees that a new module does not (its own, those it imports,
    # and those of its `using X: name`s), except the module's own name
    visible_anywhere(n) = (n in names(Base) && isdefined(Base, n)) || (n in names(Core) && isdefined(Core, n))
    candidates = names(mod; all = true, imported = true, usings = true)
    imports = sort!([n for n in candidates
                     if !startswith(String(n), '#') && n ∉ (:eval, :include, m) && isdefined(mod, n) &&
                        !(visible_anywhere(n) && getglobal(mod, n) === (isdefined(Base, n) ? getglobal(Base, n) : getglobal(Core, n))) &&
                        !(getglobal(mod, n) isa Module && n in uses)])
    append!(imports, extra_imports)
    out = IOBuffer()
    println(out, "# GENERATED by gen/specialize_callbacks.jl from $m $(pkgversion(mod)) (Julia $VERSION): do not edit.")
    println(out, "# Each definition below is the stdlib's, from the file and line named before it, with its")
    println(out, "# `::Function` arguments specialized on (`WasmF<n> <: Function`).")
    println(out)
    println(out, "using $m: ", join(map(n -> Base.isidentifier(n) || startswith(String(n), '@') ? String(n) : "var\"$n\"", imports), ", "))
    # (the modules the module's code `using`s: their exported names, as the module sees them)
    for u in uses
        println(out, "using $m: $u")
        println(out, "using .$u")
    end
    println(out)
    expected = Any[]
    count = 0
    for file in files
        for (name, def, line) in definitions(joinpath(src, file); also)
            sigstr = sprint(show, strip_lines(def.args[1]))
            any(s -> s[1] === name && occursin(s[2], sigstr), skip) && continue
            def = haskey(rewrite, name) ? rewrite[name](def) : def
            def = Expr(:function, qualified(def.args[1], m), def.args[2])
            ex = Expr(:macrocall, OVERLAY, LineNumberNode(0), TABLE, strip_lines(def))
            macro_lines!(l -> LineNumberNode(l.line, Symbol(string(m, "/src/", basename(String(something(l.file, :none)))))), ex)
            push!(expected, normalized(ex))
            println(out, "# $m/src/$file:$line")
            println(out, sprint(Base.show_unquoted, ex))
            println(out)
            count += 1
        end
    end
    text = String(take!(out))
    # (the printed code parses back to the same definitions)
    parsed = [normalized(x) for x in Meta.parseall(text).args if Meta.isexpr(x, :macrocall)]
    length(parsed) == length(expected) || error("$outfile: $(length(parsed)) definitions parsed, $(length(expected)) written")
    for (a, b) in zip(parsed, expected)
        a.args[2] = LineNumberNode(0)
        a == b || error("$outfile: a definition does not parse back to itself: ", repr(firstdiff(a, b)))
    end
    mkpath(dirname(outfile))
    write(outfile, text)
    println("$outfile: $count overlays")
end

const EXT = joinpath(dirname(@__DIR__), "ext")

# ArgTools: `arg_read`/`arg_write` of a path are written by hand in the extension (`open` with
# `lock = false` directly, without `open_nolock`'s splat)
generate(ArgTools, ("ArgTools.jl",), joinpath(EXT, "ArgToolsExt", "specialized_$(pkgversion(ArgTools)).jl");
    skip = [(:arg_read, "arg::AbstractString"), (:arg_write, "arg::AbstractString")])

# Tar: `read_standard_header`'s message of a stream that is no tarball takes the error's message
# as the String it is (`err.msg::String`; `String(err.msg)` is a dynamic call: JuliaIO/Tar.jl#206)
function err_msg(def)
    walk(x) = x isa Expr ? (y = Expr(x.head, map(walk, x.args)...); y == :(String(err.msg)) ? :(err.msg::String) : y) : x
    return walk(def)
end
generate(Tar, ("Tar.jl", "create.jl", "extract.jl", "header.jl"), joinpath(EXT, "TarExt", "specialized_$(pkgversion(Tar)).jl");
    also = [:read_standard_header], uses = [:ArgTools], rewrite = Dict{Symbol, Function}(:read_standard_header => err_msg))
