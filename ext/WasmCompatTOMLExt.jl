"""
    WasmCompatTOMLExt

TOML for WasmCodegen's closed world. Two overlays (methods of `WasmCodegen.Runtime.WASM_METHODS`,
used only when compiling to Wasm; native code is unchanged):

1. **`TOML.print` with static dispatch.** Base's printer (`Base.TOML.Printer`) dispatches on the
   `Any` values of a `Dict{String,Any}`, takes its conversion function as an unspecialized
   `::Function` and recurses through `@invokelatest`. In a closed world these are calls that
   cannot be resolved. Here `print_table` is replaced by a printer that tells each value apart by
   `isa` over the types TOML tables hold (`TOML_VALUE_TYPES` below) and then calls Base's own
   `printvalue` methods on the concrete value, so the output is byte-identical. A value of another
   type inside an `Any`-typed container is an error in Wasm (natively Base's printer runs).

2. **Long integer literals.** Base's parser reads an integer literal too long for `Int128`/`UInt128`
   as a `BigInt`, whose arithmetic is GMP's, a C library a Wasm module does not have. In Wasm such a
   literal is the parser's overflow error (`ErrOverflowError`), as a 64-bit TOML parser reports
   it. This is a documented divergence: natively the value parses as a `BigInt`.
"""
module WasmCompatTOMLExt

import TOML
import WasmCodegen
using Base: IdSet
using Base.TOML: Parser, Err, ParserError, ErrOverflowError, take_string_or_substring
using Base.TOML.Printer: printkey, BaseTOMLValue
const Printer = Base.TOML.Printer
const Dates = TOML.Dates

## 1. TOML.print

const TOMLDates = Union{Dates.DateTime, Dates.Date, Dates.Time}

"Whether `v` is a TOML value as Base's and Dates' `is_valid_toml_value` say, by `isa`."
is_valid(@nospecialize(v)) = v isa BaseTOMLValue || v isa TOMLDates

# The value types the printer tells apart in `Any`-typed containers: the parser's own output
# (with and without Dates) and the concrete containers programs commonly build.
const SCALAR_TYPES = (String, SubString{String}, Int64, Int128, UInt64, UInt128, Int32, UInt32,
    UInt8, Float64, Float32, Bool, Base.TOML.DateTime, Base.TOML.Date, Base.TOML.Time,
    Dates.DateTime, Dates.Date, Dates.Time)
const TABLE_TYPES = (Dict{String, Any}, Dict{String, String}, Dict{String, Vector{String}},
    Dict{String, Int64}, Dict{String, Bool}, Dict{String, Vector{Any}}, Dict{String, Dict{String, Any}},
    Dict{String, Dict{String, String}}, Dict{String, Vector{Dict{String, Any}}},
    Dict{String, Union{String, Vector{String}}}, Dict{String, Dates.DateTime},
    Dict{String, Vector{Dict{String, Dates.DateTime}}})
const ARRAY_TYPES = (Vector{Any}, Vector{String}, Vector{Int64}, Vector{Float64}, Vector{Bool},
    Vector{Dict{String, Any}}, Vector{Dict{String, String}}, Vector{Vector{Any}},
    Vector{Dates.DateTime}, Vector{Dates.Date}, Vector{Dates.Time}, Vector{Dict{String, Dates.DateTime}})
# values that are not TOML values but are converted by the conversion function
const CONVERTED_TYPES = (Base.UUID, Base.SHA1, VersionNumber, Nothing, Symbol)

# `isa_chain(x, types, call, otherwise)`: `x isa T1 ? call(x::T1) : x isa T2 ? ... : otherwise`
isa_chain(x::Symbol, types, call, otherwise) =
    foldr((T, rest) -> :($x isa $T ? $call($x::$T) : $rest), types; init = otherwise)

struct Unsupported
    kind::String
end
@noinline unsupported(u::Unsupported) =
    error("TOML.print (WasmCompat, Wasm): ", u.kind, " of a type the closed-world printer does not ",
        "know; supported are the types of WasmCompatTOMLExt.SCALAR_TYPES, TABLE_TYPES, ARRAY_TYPES")

# `g(x)` with `x` of its concrete type
@eval @inline function with_value(g::G, @nospecialize(x)) where {G}
    return $(isa_chain(:x, (SCALAR_TYPES..., TABLE_TYPES..., ARRAY_TYPES...), :g, :(unsupported(Unsupported("a value")))))
end
@eval @inline function with_table(g::G, @nospecialize(x)) where {G}
    return $(isa_chain(:x, TABLE_TYPES, :g, :(unsupported(Unsupported("a table")))))
end
@eval @inline function with_array(g::G, @nospecialize(x)) where {G}
    return $(isa_chain(:x, ARRAY_TYPES, :g, :(unsupported(Unsupported("an array")))))
end

# `Printer.to_toml_value` with the conversion function specialized on
function converted(f::F, value::T) where {F, T}
    if f === identity
        error("type `$(T)` is not a valid TOML type, pass a conversion function to `TOML.print`")
    end
    toml_value = f(value)
    if !is_valid(toml_value)
        error("TOML syntax function for type `$(T)` did not return a valid TOML type but a `$(typeof(toml_value))`")
    end
    return toml_value
end

# the value as `print_table` and `printvalue` use it: converted by `f` if it is not a TOML value
@eval function valid_value(f::F, @nospecialize(value)) where {F}
    is_valid(value) && return value
    return $(isa_chain(:value, CONVERTED_TYPES, :(v -> converted(f, v)), :(unsupported(Unsupported("a value to convert")))))
end

is_table(@nospecialize(value)) = value isa AbstractDict
function is_array_of_tables(@nospecialize(value))
    value isa AbstractArray || return false
    return with_array(value) do a
        length(a) > 0 && (a isa AbstractArray{<:AbstractDict} || all(v -> v isa AbstractDict, a))
    end
end
is_tabular(@nospecialize(value)) = is_table(value) || is_array_of_tables(value)

# `Printer.printvalue(f, io, value, sorted)` of a value of any type
function printvalue(f::F, io::IO, @nospecialize(value), sorted::Bool) where {F}
    value = valid_value(f, value)
    return with_value(x -> printvalue_typed(f, io, x, sorted), value)
end
printvalue_typed(f::F, io::IO, value, sorted::Bool) where {F} = Printer.printvalue(f, io, value, sorted)
function printvalue_typed(f::F, io::IO, value::AbstractVector, sorted::Bool) where {F}
    Base.print(io, "[")
    for (i, x) in enumerate(value)
        i != 1 && Base.print(io, ", ")
        printvalue(f, io, x, sorted)
    end
    Base.print(io, "]")
end
printvalue_typed(f::F, io::IO, value::AbstractDict, sorted::Bool) where {F} =
    print_inline_table(f, io, value, sorted)

function print_inline_table(f::F, io::IO, value::AbstractDict, sorted::Bool) where {F}
    vkeys = collect(keys(value))
    if sorted
        sort!(vkeys)
    end
    Base.print(io, "{")
    for (i, k) in enumerate(vkeys)
        v = value[k]
        i != 1 && Base.print(io, ", ")
        printkey(io, [String(k)])
        Base.print(io, " = ")
        printvalue(f, io, v, sorted)
    end
    Base.print(io, "}")
end

"""
    print_table(f, io, a, ks, indent, first_block, sorted, inline_tables, by)

`Base.TOML.Printer.print_table` (keyword arguments made positional) with static dispatch: the
same output byte for byte.
"""
function print_table(f::F, io::IO, a::AbstractDict, ks::Vector{String}, indent::Int, first_block::Bool,
        sorted::Bool, inline_tables::IdSet, by::B) where {F, B}
    if a in inline_tables
        print_inline_table(f, io, a, sorted)
        return
    end
    # (Base iterates `keys(a)` unsorted: the same order as collected)
    akeys = collect(keys(a))
    if sorted
        sort!(akeys; by)
    end
    # first the non-tabular entries
    for key in akeys
        value = valid_value(f, a[key])
        if is_tabular(value) && !(value in inline_tables)
            continue
        end
        Base.print(io, ' '^4max(0, indent - 1))
        printkey(io, [String(key)])
        Base.print(io, " = ")
        printvalue(f, io, value, sorted)
        Base.print(io, "\n")
        first_block = false
    end
    for key in akeys
        value = valid_value(f, a[key])
        if is_table(value) && !(value in inline_tables)
            push!(ks, String(key))
            fb = first_block # (not captured itself: a captured variable that is reassigned is boxed)
            first_block = with_table(t -> print_subtable(f, io, t, ks, indent, fb, sorted, inline_tables, by), value)
            pop!(ks)
        elseif is_array_of_tables(value)
            first_block || println(io)
            first_block = false
            push!(ks, String(key))
            with_array(value) do arr
                for v in arr
                    Base.print(io, ' '^4indent)
                    Base.print(io, "[[")
                    printkey(io, ks)
                    Base.print(io, "]]\n")
                    !isa(v, AbstractDict) && error("array should contain only tables")
                    with_table(t -> print_table(f, io, t, ks, indent + 1, true, sorted, inline_tables, by), v)
                end
            end
            pop!(ks)
        end
    end
    return nothing
end

# a table entry of `print_table`'s second loop; returns `first_block` after it
function print_subtable(f::F, io::IO, value::AbstractDict, ks::Vector{String}, indent::Int, first_block::Bool,
        sorted::Bool, inline_tables::IdSet, by::B) where {F, B}
    _values = values(value)
    header = isempty(value) || !all(v -> is_tabular(v), _values) || any(v -> v in inline_tables, _values)
    if header
        first_block || println(io)
        first_block = false
        Base.print(io, ' '^4indent)
        Base.print(io, "[")
        printkey(io, ks)
        Base.print(io, "]\n")
    end
    print_table(f, io, value, ks, indent + header, header, sorted, inline_tables, by)
    return first_block
end

# The overlay: the entry `print`'s four methods call. `f::F` and the untyped `by` are the same
# signature as Base's method (which it replaces in Wasm), with both functions specialized on:
# Julia does not specialize on an argument declared `::Function` that is only passed on.
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Printer.print_table(
        f::F, io::IO, a::AbstractDict, ks::Vector{String} = String[];
        indent::Int = 0, first_block::Bool = true, sorted::Bool = false, inline_tables::IdSet,
        by = identity) where {F <: Function}
    print_table(f, io, a, ks, indent, first_block, sorted, inline_tables, by)
end

## 2. Long integer literals

for (name, T1, T2, n1, n2) in (("integer", Int64, Int128, 17, 33),
                               ("hex", UInt64, UInt128, 18, 34),
                               ("oct", UInt64, UInt128, 24, 45),
                               ("bin", UInt64, UInt128, 66, 130))
    f = Symbol("parse_", name)
    @eval Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Base.TOML.$f(
            l::Parser, contains_underscore, base = nothing)::Err{Union{$T1, $T2, BigInt}}
        s = take_string_or_substring(l, contains_underscore)
        len = length(s)
        v = try
            if len ≤ $n1
                Base.parse($T1, s; base)
            elseif $n1 < len ≤ $n2
                Base.parse($T2, s; base)
            else
                # (natively `Base.parse(BigInt, s; base)`)
                return ParserError(ErrOverflowError)
            end
        catch e
            e isa Base.OverflowError && return ParserError(ErrOverflowError)
            rethrow()
        end
        return v
    end
end

end # module
