# 69 patterns through Base's Regex in Wasm on PCRE2 (WasmCompatPCRE2Ext; check.sh with PCRE2=1), against native
# PCRE2: each `Regex(pattern, flags)`, then `eachmatch` with captures, `keys` of the first match, and
# `replace(subject, r => s"<\0>")`, which reads the subject back through `pcre2_substring_copy_bynumber`.
# Group A: ordinary features; group B: constructs only PCRE2 has; group C: errors, options and edge cases.
module Prog

const CORPUS = Tuple{String,String,String}[
    # A: ordinary
    ("a+", "", "caaab aa"),
    ("(\\d+)-(\\d+)", "", "10-20, 3-4"),
    ("(?<y>\\d{4})-(?<m>\\d\\d)", "", "on 2026-11 and 1999-01"),
    ("\\bfoo\\b", "i", "Foo food FOO"),
    ("^x", "m", "x\nax\nx"),
    ("\\p{L}+", "", "héllo, мир! 世界"),
    ("straße", "i", "STRASSE Straße STRAßE"),
    ("foo(?=bar)", "", "foobar foobaz"),
    ("(?<=\\\$)\\d+", "", "cost \$42 or 7"),
    ("(\\w)\\1", "", "aabbcd"),
    ("a.*?b", "", "aXbYb"),
    ("(?>a+)b", "", "aaab"),
    ("a++b", "", "aaab aa"),
    ("\\w+", "", "été naïve ٣٤"),
    ("\\d+", "", "x ٣٤ 56"),
    ("[[:alpha:]]+", "", "ab1cd"),
    ("\\Qa.b\\E+", "", "a.bbb a.b"),
    ("a b # comment", "x", "ab a b"),
    ("x*", "", "axxb"),
    ("\$", "", "line\n"),
    (".", "s", "\n"),
    ("\\R", "", "a\r\nb\nc"),
    ("\\h+\\v", "", "a \t\nb"),
    ("(?i)ǅ", "", "ǄǅǆDž"),
    ("\\p{Greek}+", "", "abc αβγ"),
    ("(a)|(b)", "", "ab"),
    ("(?<=a|bc)x", "", "ax bcx cx"),
    ("[^\\x00-\\x7f]+", "", "abc é 漢字"),
    ("é", "", "caf\xe9 café"),
    ("(?:ab){2,3}", "", "abababab"),
    ("\\g{-1}", "", "x"),
    ("(a)\\g{-1}", "", "aa"),
    # B: constructs only PCRE2 has
    ("\\((?:[^()]|(?R))*\\)", "", "f(a(b)c) (x"),
    ("(?<d>\\d)(?&d)", "", "12a34"),
    ("(a)?(?(1)b|c)", "", "ab c"),
    ("(?|(a)|(b))", "", "ab"),
    ("a(*SKIP)(*FAIL)|b", "", "ab"),
    ("foo\\Kbar", "", "foobar"),
    ("\\Ga", "", "aab"),
    ("\\X", "", "éx"),
    ("(?<n>a)|(?<n>b)", "", "b"),
    ("(*UCP)\\w", "a", "é"),
    ("(?<=(a))b", "", "ab"),
    ("(?<=\\d+)x", "", "12x"),
    ("(?:a|)*b", "", "aab"),
    ("(a|b)*?c", "", "abc"),
    ("(*sr:\\w+)", "", "Ab1 αβ"),
    ("\\p{Zyyy}", "", "1"),
    ("[[:<:]]a", "", "a ba"),
    ("(?*a)b", "", "ab"),
    ("\\C", "", "é"),
    ("(?(DEFINE)(?<w>\\w+))(?&w)", "", "hi"),
    ("\\g<1>(a)", "", "aa"),
    ("(?:(a)|b)\\1", "", "aa ba"),
    # C: errors, options, edge cases
    ("a{2,1}", "", ""),
    ("(", "", ""),
    ("[z-a]", "", ""),
    ("\\", "", ""),
    ("(?<n>a)(?<n>b)", "", ""),
    ("a**", "", ""),
    ("\\p{Nope}", "", ""),
    ("(?<=a+)b", "", ""),
    ("a", "", "\xff\xfea\xff"),
    ("", "", "abc"),
    ("(?=a)", "", "aa"),
    ("\\x{1F600}", "", "x😀y"),
    ("[\\x{100}-\\x{10FFFF}]", "", "aĀb"),
    ("^.\$", "a", "é"),
    ("(?i:K)", "", "KK k"),
]

function show_str(io::IO, s::AbstractString)
    print(io, '"', escape_string(s), '"')
end

function show_err(io::IO, tag::String, @nospecialize(e))
    print(io, tag)
    if e isa ErrorException && e.msg isa String
        print(io, e.msg::String)
    else
        print(io, "non-ErrorException")
    end
end

function run_case(io::IO, i::Int, p::String, f::String, s::String)
    print(io, i, ":")
    r = try
        Regex(p, f)
    catch e
        show_err(io, " E ", e)
        print(io, "\n")
        return nothing
    end
    n = 0
    first = true
    try
        for m in eachmatch(r, s)
            n += 1
            print(io, " [", m.offset, " ")
            show_str(io, m.match)
            for c in m.captures
                if c === nothing
                    print(io, " -")
                else
                    print(io, " ")
                    show_str(io, c)
                end
            end
            if first
                first = false
                for k in keys(m)
                    print(io, " k=")
                    k isa Int ? print(io, k::Int) : k isa String ? print(io, k::String) : print(io, "?")
                end
            end
            print(io, "]")
            n >= 20 && break
        end
    catch e
        show_err(io, " M ", e)
    end
    n == 0 && print(io, " none")
    try
        print(io, " R ")
        show_str(io, replace(s, r => s"<\0>"))
    catch e
        show_err(io, " RE ", e)
    end
    print(io, "\n")
    return nothing
end

function corpus_text()
    io = IOBuffer()
    for (i, (p, f, s)) in enumerate(CORPUS)
        run_case(io, i, p, f, s)
    end
    return String(take!(io))
end

function main()
    print(Core.stdout, corpus_text())
    return Int32(0)
end

end # Prog
