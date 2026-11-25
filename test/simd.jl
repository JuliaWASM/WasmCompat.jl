# WasmCompatSIMDExt and WasmCompatBaseExt, natively: each lane overlay (`lane_<name>`, the same
# method as the overlay) against SIMD.jl's own LLVM intrinsic, and the overlays' presence in
# WasmCodegen's table. Included by runtests.jl; standalone: julia --project=<env> test/simd.jl
# (an environment with WasmCodegen, WasmCompat, SIMD and Test).
using Test, WasmCodegen, WasmCompat
import SIMD

@testset "SIMD.jl lanes and generating_output" begin
    SIMDExt = Base.get_extension(WasmCompat, :WasmCompatSIMDExt)
    BaseExt = Base.get_extension(WasmCompat, :WasmCompatBaseExt)
    @test SIMDExt isa Module
    @test BaseExt isa Module
    SI = SIMD.Intrinsics
    L(f) = getfield(SIMDExt, Symbol(:lane_, f))
    lv(v) = map(VecElement, Tuple(v))
    vals(t::Tuple) = map(x -> x isa VecElement ? x.value : vals(x), t)
    vals(x) = x
    same(a, b) = isequal(vals(a), vals(b))          # NaN == NaN, -0.0 != 0.0
    near(a, b) = all(isapprox.(vals(a), vals(b); rtol = 4eps(eltype(vals(b)))))

    @testset "overlays are in WasmCodegen's table, one per lane function" begin
        ov = Set{Symbol}()
        Base.visit(WasmCodegen.Runtime.WASM_METHODS) do m
            m.module === SIMDExt && push!(ov, m.name)
        end
        lanes = Set(Symbol(string(n)[6:end]) for n in names(SIMDExt; all = true) if startswith(string(n), "lane_"))
        @test length(lanes) > 90
        @test lanes == ov
        @test all(f -> isdefined(SI, f), lanes)
    end

    @testset "floats: $T" for T in (Float64, Float32)
        x = lv(T[1.5, -2.25, NaN, 7.0]); y = lv(T[0.5, NaN, 3.0, -4.0]); z = lv(T[2.0, 1.0, -1.0, 0.25])
        for f in (:fadd, :fsub, :fmul, :fdiv, :frem, :minimum, :maximum, :copysign)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
            @test same(L(f)(x, y, SI.FastMathFlags{0}()), getfield(SI, f)(x, y))
        end
        for f in (:fadd, :fsub, :fmul, :fdiv)
            @test same(L(f)(T(1.25), T(-3)), getfield(SI, f)(T(1.25), T(-3)))
        end
        # minnum/maxnum: the operand that is not NaN (and no ±0 pair, whose order LLVM leaves open)
        for f in (:minnum, :maxnum)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        @test same(L(:fneg)(x), SI.fneg(x))
        @test same(L(:fma)(x, y, z), SI.fma(x, y, z))
        @test near(L(:fmuladd)(lv(T[1, 2, 3, 4]), z, z), SI.fmuladd(lv(T[1, 2, 3, 4]), z, z))
        p = lv(T[2.25, 0.5, 9.0, 1.0e3]); r = lv(T[-2.5, 2.5, 3.5, -0.5])
        for f in (:sqrt, :fabs, :floor, :ceil, :trunc, :rint, :nearbyint, :round)
            @test same(L(f)(r), getfield(SI, f)(r))
            @test same(L(f)(p), getfield(SI, f)(p))
        end
        for f in (:sin, :cos, :exp, :exp2, :log, :log10, :log2)
            @test near(L(f)(p), getfield(SI, f)(p))
            @test near(L(f)(T(0.75)), getfield(SI, f)(T(0.75)))
        end
        @test near(L(:pow)(p, z), SI.pow(p, z))
        # pow of a negative base: NaN for an exponent that is not an integer (Julia's `^` throws), and the limits
        b = lv(T[-1, -8, -2, -0.5, -Inf, -Inf, -Inf, -Inf, -2, -2, -1, NaN])
        e = lv(T[0.5, 1 / 3, 3, -2, 0.5, -0.5, 3, -3, Inf, -Inf, NaN, 0.5])
        @test_throws DomainError T(-1)^T(0.5)
        @test same(L(:pow)(b, e), SI.pow(b, e))
        # a base of ±0: the sign of -0.0 for an odd integer exponent, a large one too (where Julia's `^` loses it)
        for z in (T(0), -T(0))
            ez = lv(T[3, -3, 4097, -4097, 65537, -65537, 2, -2, 4096, -4096, 0.5, -0.5, Inf, -Inf, 0, NaN])
            @test same(L(:pow)(lv(fill(z, 16)), ez), SI.pow(lv(fill(z, 16)), ez))
        end
        for flag in (:oeq, :one, :ogt, :oge, :olt, :ole, :ord, :uno, :ueq, :une, :ugt, :uge, :ult, :ule, :false, :true)
            f = Symbol("fcmp_", flag)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        c = lv(Bool[1, 0, 1, 0])
        @test same(L(:select)(c, x, y), SI.select(c, x, y))
        e = lv(T[1, 2, 3, 4])                     # exact in any order of summation
        @test same(L(:reduce_fadd)(e), SI.reduce_fadd(e))
        @test same(L(:reduce_fmul)(e), SI.reduce_fmul(e))
        @test near(L(:reduce_fadd)(p), SI.reduce_fadd(p))
        for f in (:reduce_fmaximum, :reduce_fminimum, :reduce_fmax, :reduce_fmin)
            isdefined(SI, f) && @test same(L(f)(p), getfield(SI, f)(p))
        end
    end

    @testset "integers: $T" for T in (Int8, UInt8, Int32, UInt32, Int64, UInt64)
        x = lv(T[typemax(T), 3, typemin(T), 100]); y = lv(T[1, 7, 2, 9]); s = lv(T[1, 3, 8 * sizeof(T) - 1, 0])
        for f in (:add, :sub, :mul, :and, :or, :xor, :sdiv, :udiv, :srem, :urem)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        @test same(L(:add)(T(5), T(9)), SI.add(T(5), T(9)))
        for f in (:shl, :ashr, :lshr)
            @test same(L(f)(x, s), getfield(SI, f)(x, s))
        end
        for f in (:bswap, :bitreverse, :ctpop, :ctlz, :cttz)
            @test same(L(f)(x), getfield(SI, f)(x))
            @test same(L(f)(T(6)), getfield(SI, f)(T(6)))
        end
        for f in (:fshl, :fshr)
            @test same(L(f)(x, y, s), getfield(SI, f)(x, y, s))
        end
        for f in (:sadd_sat, :uadd_sat, :ssub_sat, :usub_sat)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        for f in (:sadd_with_overflow, :uadd_with_overflow, :ssub_with_overflow, :usub_with_overflow,
                  :smul_with_overflow, :umul_with_overflow)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        for flag in (:eq, :ne, :sgt, :sge, :slt, :sle, :ugt, :uge, :ult, :ule)
            f = Symbol("icmp_", flag)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        for f in (:reduce_and, :reduce_or, :reduce_mul, :reduce_add, :reduce_smax, :reduce_smin, :reduce_umax, :reduce_umin)
            @test same(L(f)(x), getfield(SI, f)(x))
        end
    end

    @testset "lanes, conversions, masks" begin
        x = lv([1.5, -2.0, 3.25, 4.0]); y = lv([10.0, 20.0, 30.0, 40.0])
        @test same(L(:extractelement)(x, 2), SI.extractelement(x, 2))
        @test same(L(:insertelement)(x, 9.0, 1), SI.insertelement(x, 9.0, 1))
        @test same(L(:constantvector)(2.5, SIMD.LVec{4,Float64}), SI.constantvector(2.5, SIMD.LVec{4,Float64}))
        @test same(L(:shufflevector)(x, y, Val((0, 5, 2, 7))), SI.shufflevector(x, y, Val((0, 5, 2, 7))))
        @test same(L(:shufflevector)(x, Val((3, 2, 1, 0, 0))), SI.shufflevector(x, Val((3, 2, 1, 0, 0))))
        # an `:undef` index: a lane of any value (the others as natively)
        @test same(L(:shufflevector)(x, Val((2, :undef, 0)))[[1, 3]], SI.shufflevector(x, Val((2, :undef, 0)))[[1, 3]])
        @test same(L(:shufflevector)(x, y, Val((:undef, 6)))[2], SI.shufflevector(x, y, Val((:undef, 6)))[2])
        # one vector: an index into the second, which is undefined (a lane of any value; the others as natively)
        @test same(L(:shufflevector)(x, Val((1, 4, 7, 3)))[[1, 4]], SI.shufflevector(x, Val((1, 4, 7, 3)))[[1, 4]])
        # an index that is not an integer: SIMD.jl's TypeError
        for I in ((1.0, 0.0), (:x, 0))
            @test_throws TypeError SI.shufflevector(x, Val(I))
            @test_throws TypeError L(:shufflevector)(x, Val(I))
            @test_throws TypeError SI.shufflevector(x, y, Val(I))
            @test_throws TypeError L(:shufflevector)(x, y, Val(I))
        end
        i = lv(Int32[-3, 7, 1 << 20, 0])
        @test same(L(:sitofp)(SIMD.LVec{4,Float64}, i), SI.sitofp(SIMD.LVec{4,Float64}, i))
        # (toward zero: 1.5 is 1 and -2.5 is -2)
        fr = lv([1.5, -2.5, 3.25, 200.75])
        @test same(L(:fptosi)(SIMD.LVec{4,Int64}, fr), SI.fptosi(SIMD.LVec{4,Int64}, fr))
        @test same(L(:fptosi)(SIMD.LVec{4,Int32}, fr), SI.fptosi(SIMD.LVec{4,Int32}, fr))
        @test same(L(:fptoui)(SIMD.LVec{4,UInt8}, lv(Float32[1.5, 0.9, 3.25, 200.75])), SI.fptoui(SIMD.LVec{4,UInt8}, lv(Float32[1.5, 0.9, 3.25, 200.75])))
        # signed or unsigned as the intrinsic is, whatever the lanes' type: -2 in a UInt32, 200 in an Int8
        @test same(L(:fptosi)(SIMD.LVec{4,UInt32}, fr), SI.fptosi(SIMD.LVec{4,UInt32}, fr))
        @test same(L(:fptoui)(SIMD.LVec{4,Int8}, lv([200.5, 255.9, 1.5, 0.0])), SI.fptoui(SIMD.LVec{4,Int8}, lv([200.5, 255.9, 1.5, 0.0])))
        @test same(L(:fptoui)(SIMD.LVec{4,Int32}, lv([3.0e9, 4.0e9, 1.5, 0.0])), SI.fptoui(SIMD.LVec{4,Int32}, lv([3.0e9, 4.0e9, 1.5, 0.0])))
        # to Bool (convert(Vec{4,Bool}, ::Vec{4,Float64}) is fptoui)
        fb = lv([1.0, 0.0, 0.0, 1.0])
        @test same(L(:fptoui)(SIMD.LVec{4,Bool}, fb), SI.fptoui(SIMD.LVec{4,Bool}, fb))
        @test same(L(:fptosi)(SIMD.LVec{4,Bool}, fb), SI.fptosi(SIMD.LVec{4,Bool}, fb))
        @test same(L(:fptrunc)(SIMD.LVec{4,Float32}, x), SI.fptrunc(SIMD.LVec{4,Float32}, x))
        @test same(L(:fpext)(SIMD.LVec{4,Float64}, lv(Float32[1.5, 2, 3, 4])), SI.fpext(SIMD.LVec{4,Float64}, lv(Float32[1.5, 2, 3, 4])))
        @test same(L(:sext)(SIMD.LVec{4,Int64}, i), SI.sext(SIMD.LVec{4,Int64}, i))
        @test same(L(:zext)(SIMD.LVec{4,UInt64}, lv(UInt32[1, 2, typemax(UInt32), 4])), SI.zext(SIMD.LVec{4,UInt64}, lv(UInt32[1, 2, typemax(UInt32), 4])))
        @test same(L(:trunc)(SIMD.LVec{4,Int8}, i), SI.trunc(SIMD.LVec{4,Int8}, i))
        @test same(L(:bitcast)(SIMD.LVec{4,UInt64}, x), SI.bitcast(SIMD.LVec{4,UInt64}, x))
        @test same(L(:bitcast)(UInt64, 1.5), SI.bitcast(UInt64, 1.5))
        # to another number of lanes, and between a vector and a scalar: the same bytes
        for (T, v) in ((SIMD.LVec{8,UInt32}, x), (SIMD.LVec{2,UInt128}, x), (SIMD.LVec{32,UInt8}, x), (SIMD.LVec{16,Int16}, x),
                       (SIMD.LVec{2,Float64}, lv(UInt32[1, 0x3ff80000, 0xdeadbeef, 0xc0000000])), (SIMD.LVec{2,Float32}, lv([-1.5f0, 2.0f0])),
                       (SIMD.LVec{4,Float32}, lv(Int8.(-8:7))), (SIMD.LVec{2,Float64}, typemax(UInt128) >> 3), (SIMD.LVec{8,Bool}, 0x0100010100000001),
                       (UInt64, lv([1.5f0, -2.0f0])), (Float64, lv(UInt8.(1:8))), (UInt128, lv([1.5, -2.5])), (Int16, lv(Bool[1, 0])))
            @test same(L(:bitcast)(T, v), SI.bitcast(T, v))
        end
        @test_throws ArgumentError SI.bitcast(SIMD.LVec{4,UInt32}, x)
        @test_throws ArgumentError L(:bitcast)(SIMD.LVec{4,UInt32}, x)
        @test_throws ArgumentError L(:bitcast)(UInt32, x)
        @test_throws ArgumentError L(:bitcast)(SIMD.LVec{4,UInt32}, 1.5)
        # scalars of two sizes: SIMD.jl's ArgumentError
        msg = "size of conversion type (Int64: 64) must be equal to the vector type (UInt8: 8)"
        @test_throws ArgumentError(msg) SI.bitcast(Int64, 0x01)
        @test_throws ArgumentError(msg) L(:bitcast)(Int64, 0x01)
        # 3 lanes of UInt8 are 24 bits in a type of 32: LLVM's error natively, not the sizes' ArgumentError
        @test_throws ErrorException SI.bitcast(UInt32, lv([0x01, 0x02, 0x03]))
        @test_throws "(24 bits) to UInt32 (32 bits)" L(:bitcast)(UInt32, lv([0x01, 0x02, 0x03]))
        @test_throws ErrorException L(:bitcast)(SIMD.LVec{3,UInt8}, 0x01020304)
        # a lane type SIMD.jl has no LLVM type for, a pointer: its KeyError
        p = lv(Ptr{UInt8}[1, 2])
        for (T, v) in ((sizeof(Int) == 8 ? UInt128 : UInt64, p), (SIMD.LVec{2,UInt}, p), (SIMD.LVec{2 * sizeof(Int),UInt8}, p),
                       (SIMD.LVec{2,Ptr{UInt8}}, lv(UInt[1, 2])), (SIMD.LVec{2,Ptr{UInt8}}, p),
                       # (before the bits are compared: 3 lanes and 4 of one padded size)
                       (SIMD.LVec{4,UInt}, lv(Ptr{UInt8}[1, 2, 3])), (SIMD.LVec{3,Ptr{UInt8}}, lv(UInt[1, 2, 3, 4])))
            @test_throws KeyError(Ptr{UInt8}) SI.bitcast(T, v)
            @test_throws KeyError(Ptr{UInt8}) L(:bitcast)(T, v)
        end
        # (the lane type of a vector of vectors is a vector, not one of those either)
        @test_throws KeyError(SIMD.LVec{2,UInt8}) SI.bitcast(SIMD.LVec{1,SIMD.LVec{2,UInt8}}, lv([0x01, 0x02]))
        @test_throws KeyError(SIMD.LVec{2,UInt8}) L(:bitcast)(SIMD.LVec{1,SIMD.LVec{2,UInt8}}, lv([0x01, 0x02]))
        # (and after the sizes)
        @test_throws ArgumentError SI.bitcast(SIMD.LVec{2,UInt32}, lv(Ptr{UInt8}[1, 2, 3]))
        @test_throws ArgumentError L(:bitcast)(SIMD.LVec{2,UInt32}, lv(Ptr{UInt8}[1, 2, 3]))
        m = lv(Bool[1, 0, 1, 1])
        @test same(L(:bitmask)(m), SI.bitmask(m))
        @test same(L(:bitmask)(ntuple(k -> VecElement(isodd(k)), 128)), SI.bitmask(ntuple(k -> VecElement(isodd(k)), 128)))
        @test_throws ArgumentError("vector length 129 must be <= 128") SI.bitmask(ntuple(k -> VecElement(true), 129))
        @test_throws ArgumentError("vector length 129 must be <= 128") L(:bitmask)(ntuple(k -> VecElement(true), 129))
        @test same(L(:reduce_add)(m), SI.reduce_add(m))
    end

    @testset "memory" begin
        a = collect(1.0:8.0); b = zeros(8); c = zeros(8)
        m = lv(Bool[1, 0, 1, 1])
        GC.@preserve a b c begin
            p = pointer(a, 2)
            @test same(L(:load)(SIMD.LVec{4,Float64}, p), SI.load(SIMD.LVec{4,Float64}, p))
            @test same(L(:maskedload)(p, m), SI.maskedload(p, m))
            @test same(L(:maskedexpandload)(p, m), SI.maskedexpandload(p, m))
            ptrs = lv([pointer(a, 8), pointer(a, 1), pointer(a, 5), pointer(a, 3)])
            @test same(L(:maskedgather)(ptrs, m), SI.maskedgather(ptrs, m))
            v = lv([-1.0, -2.0, -3.0, -4.0])
            for (f, args) in ((:store, ()), (:maskedstore, (m,)), (:maskedcompressstore, (m,)))
                fill!(b, 0); fill!(c, 0)
                L(f)(v, pointer(b, 3), args...); getfield(SI, f)(v, pointer(c, 3), args...)
                @test b == c
            end
            fill!(b, 0); fill!(c, 0)
            L(:maskedscatter)(v, lv([pointer(b, 8), pointer(b, 1), pointer(b, 5), pointer(b, 3)]), m)
            SI.maskedscatter(v, lv([pointer(c, 8), pointer(c, 1), pointer(c, 5), pointer(c, 3)]), m)
            @test b == c
        end
    end

    @testset "generating_output: false in Wasm" begin
        ov = Method[]
        Base.visit(m -> m.module === BaseExt && push!(ov, m), WasmCodegen.Runtime.WASM_METHODS)
        @test any(m -> m.name === :generating_output, ov)
    end
end
