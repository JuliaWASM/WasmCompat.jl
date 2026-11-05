# WasmCompatTarExt + WasmCompatArgToolsExt: Tar.create, list, extract (with a predicate), tree_hash,
# and the error for a stream that is no tarball
module Prog
import Tar
out(xs...) = (for x in xs; write(Core.stdout, x); end; write(Core.stdout, "\n"))
function main()
    root = ENV["WORK"]
    src = joinpath(root, "src")
    mkpath(joinpath(src, "sub"))
    write(joinpath(src, "a.txt"), "hello\n")
    write(joinpath(src, "sub", "b.txt"), "world\n")
    tb = joinpath(root, "t.tar")
    Tar.create(src, tb)
    for h in Tar.list(tb)
        out(h.path, " ", String(h.type), " ", string(h.size))
    end
    dst = joinpath(root, "out")
    Tar.extract(tb, dst)
    out(read(joinpath(dst, "sub", "b.txt"), String))
    out("tree_hash ", Tar.tree_hash(tb))
    dst2 = joinpath(root, "out2")
    Tar.extract(h -> h.path != "a.txt", tb, dst2)
    out(join(sort!(readdir(dst2)), ","))
    open(tb) do io
        out("from IO: ", string(length(Tar.list(io))))
    end
    write(joinpath(root, "bad.tar"), repeat("x", 1024))
    try
        Tar.list(joinpath(root, "bad.tar"))
        out("no error")
    catch e
        out(e isa ErrorException && e.msg isa String ? first(e.msg::String, 70) : "another error")
    end
    return 0
end
end
