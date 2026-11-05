# Julia's LibGit2 in Wasm on libgit2 (WasmCompatLibGit2Ext; `LIBGIT2=1 check.sh git`), against native libgit2: the
# operations Pkg performs, through LibGit2's own API, on repositories this program makes in $WORK (fixed signatures,
# so every hash is the same in both runs): init/add!/commit, open, revparse and objects, trees and blobs, HEAD and
# branches, configuration, remotes, clone (local and file://), fetch with refspecs, checkout of a tree into a directory
# (Pkg's checkout_tree_to_path), isdirty, reset!, fast-forward merge!, rebase!, and libgit2's errors. With NET=1, a
# shallow clone over https and an unshallow fetch, Pkg's way.
module Prog

using LibGit2

const SIG = LibGit2.Signature("Tester", "tester@example.org", 1767225600, 0)

w(io::IO, x::Union{String,SubString{String},Bool,Int,Int32,UInt32,Symbol}) = print(io, x)
w(io::IO, x::LibGit2.GitHash) = print(io, string(x))
w(io::IO, ::Nothing) = print(io, "nothing")
ln(io::IO) = println(io)
ln(io::IO, x, xs...) = (w(io, x); print(io, ' '); ln(io, xs...))

function err(io::IO, label::String, e)
    if e isa LibGit2.GitError
        ln(io, label, "GitError", Int(e.code), Int(e.class), e.msg)
    else
        msg = e isa ErrorException ? "ErrorException: " * (e.msg::String) :
              e isa ArgumentError ? "ArgumentError: " * (e.msg::String) :
              e isa AssertionError ? "AssertionError: " * (e.msg::String) :
              e isa KeyError ? "KeyError" : e isa BoundsError ? "BoundsError" : e isa MethodError ? "MethodError" :
              e isa InexactError ? "InexactError" : e isa SystemError ? "SystemError: " * (e.prefix::String) :
              e isa Base.IOError ? "IOError: " * (e.msg::String) : "another exception"
        ln(io, label, "other error:", msg)
    end
end

function write_files(root::String, files::Vector{Pair{String,String}})
    for (p, c) in files
        f = joinpath(root, p)
        mkpath(dirname(f))
        write(f, c)
    end
end

function commit_all(repo::LibGit2.GitRepo, msg::String)
    LibGit2.add!(repo, ".")
    return LibGit2.commit(repo, msg; author = SIG, committer = SIG)
end

# the files of a directory, sorted, with their contents' lengths (no host paths)
function listing(io::IO, dir::String)
    for (root, dirs, files) in walkdir(dir)
        sort!(dirs); sort!(files)
        for f in files
            p = joinpath(root, f)
            ln(io, "  file", relpath(p, dir), filesize(p))
        end
    end
end

function local_ops(io::IO, W::String)
    # a repository made here: two commits on the default branch, a tag, a second branch
    up = joinpath(W, "up")
    repo = LibGit2.init(up)
    write_files(up, ["Project.toml" => "name = \"Foo\"\nversion = \"0.1.0\"\n", "src/Foo.jl" => "module Foo\nf() = 1\nend\n",
                     "sub/Bar/Project.toml" => "name = \"Bar\"\n"])
    c1 = commit_all(repo, "one\n")
    write_files(up, ["src/Foo.jl" => "module Foo\nf() = 2\nend\n"])
    c2 = commit_all(repo, "two\n")
    ln(io, "commits", c1, c2)
    ln(io, "head_oid", LibGit2.head_oid(repo), "headname", LibGit2.headname(repo), "isattached", LibGit2.isattached(repo))
    ln(io, "isbare", LibGit2.isbare(repo), "isdirty", LibGit2.isdirty(repo))
    ln(io, "path ok", LibGit2.path(repo) == up)

    # objects by spec, peeling, trees and blobs (Pkg: Types.jl, Operations.jl)
    LibGit2.with(LibGit2.GitObject(repo, "HEAD~1")) do o
        ln(io, "HEAD~1", LibGit2.GitHash(o), o isa LibGit2.GitCommit)
        t = LibGit2.peel(LibGit2.GitTree, o)
        ln(io, "tree", LibGit2.GitHash(t))
        sub = t["sub/Bar"]
        ln(io, "subtree", sub isa LibGit2.GitTree, LibGit2.GitHash(sub))
        b = t["src/Foo.jl"]
        ln(io, "blob", b isa LibGit2.GitBlob, LibGit2.content(b::LibGit2.GitBlob))
        try
            t["no/such"]
            ln(io, "missing entry", "found")
        catch e
            ln(io, "missing entry", e isa KeyError ? "KeyError" : "other")
        end
    end
    LibGit2.with(LibGit2.GitBlob(repo, "HEAD:Project.toml")) do b
        ln(io, "Project.toml at HEAD", LibGit2.content(b))
    end
    ln(io, "revparseid HEAD^{tree}", LibGit2.revparseid(repo, "HEAD^{tree}"))
    for spec in ("nosuchref", "HEAD~9", "HEAD:no/such/path", "..")
        try
            LibGit2.GitObject(repo, spec)
            ln(io, "spec", spec, "found")
        catch e
            err(io, "spec " * spec, e)
        end
    end
    ln(io, "GitObject by hash", LibGit2.GitHash(LibGit2.GitObject(repo, c1)) == c1)

    # the work tree: dirty, reset! --hard
    write(joinpath(up, "src", "Foo.jl"), "changed\n")
    ln(io, "isdirty after an edit", LibGit2.isdirty(repo))
    LibGit2.reset!(repo, c2, LibGit2.Consts.RESET_HARD)
    ln(io, "isdirty after reset!", LibGit2.isdirty(repo), read(joinpath(up, "src", "Foo.jl"), String))

    # configuration, remotes
    LibGit2.with(LibGit2.GitConfig(repo)) do cfg
        ln(io, "core.bare", LibGit2.get(cfg, "core.bare", "?"))
        ln(io, "missing key", LibGit2.get(cfg, "no.such", "default"))
    end
    rs = LibGit2.remotes(repo)
    ln(io, "remotes of up", length(rs))
    close(repo)

    # clone (bare, a local path; then file://), as GitTools.clone
    cl = joinpath(W, "clones", "Foo")
    repo2 = LibGit2.clone(up, cl; isbare = true)
    ln(io, "clone bare", LibGit2.isbare(repo2), LibGit2.head_oid(repo2))
    rs2 = LibGit2.remotes(repo2)
    ln(io, "remotes", length(rs2), join(String[String(x) for x in rs2], ","))
    LibGit2.with(LibGit2.get(LibGit2.GitRemote, repo2, "origin")) do r
        ln(io, "origin url ok", LibGit2.url(r) == up)
    end
    # Pkg's checkout_tree_to_path of the first commit's tree
    t1 = LibGit2.peel(LibGit2.GitTree, LibGit2.GitObject(repo2, string(c1)))
    out = joinpath(W, "packages", "Foo", "t1")
    mkpath(dirname(out))
    GC.@preserve out begin
        opts = LibGit2.CheckoutOptions(checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
                                       target_directory = Base.unsafe_convert(Cstring, out))
        LibGit2.checkout_tree(repo2, t1, options = opts)
    end
    ln(io, "checkout_tree into", "packages/Foo/t1")
    listing(io, out)
    close(t1)

    # upstream moves on; fetch with Pkg's refspec; fast-forward merge in a non-bare clone
    up2 = LibGit2.GitRepo(up)
    write_files(up, ["README.md" => "readme\n"])
    c3 = commit_all(up2, "three\n")
    ln(io, "upstream commit", c3)
    LibGit2.fetch(repo2; remoteurl = "file://" * up, refspecs = ["+refs/*:refs/remotes/cache/*"])
    ln(io, "fetched cache ref", LibGit2.GitHash(LibGit2.GitObject(repo2, "refs/remotes/cache/heads/" * LibGit2.headname(up2))))
    close(repo2)

    wt = joinpath(W, "wt")
    repo3 = LibGit2.clone("file://" * up, wt)
    ln(io, "work tree clone head", LibGit2.head_oid(repo3), "branch", LibGit2.branch(repo3))
    LibGit2.reset!(repo3, c1, LibGit2.Consts.RESET_HARD)
    ln(io, "reset to c1", LibGit2.head_oid(repo3))
    ok = LibGit2.merge!(repo3; branch = "refs/remotes/origin/" * LibGit2.headname(up2), fastforward = true)
    ln(io, "merge! fast-forward", ok, LibGit2.head_oid(repo3), isfile(joinpath(wt, "README.md")))

    # rebase! a local commit onto the upstream
    LibGit2.reset!(repo3, c2, LibGit2.Consts.RESET_HARD)
    write_files(wt, ["local.txt" => "mine\n"])
    LibGit2.add!(repo3, "local.txt")
    cl1 = LibGit2.commit(repo3, "local\n"; author = SIG, committer = SIG)
    ln(io, "local commit", cl1)
    LibGit2.with(LibGit2.GitConfig(repo3)) do cfg
        LibGit2.set!(cfg, "user.name", "Tester")
        LibGit2.set!(cfg, "user.email", "tester@example.org")
    end
    try
        LibGit2.rebase!(repo3, "refs/remotes/origin/" * LibGit2.headname(up2))
        h = LibGit2.head_oid(repo3)
        LibGit2.with(LibGit2.GitObject(repo3, "HEAD^")) do p
            ln(io, "rebase! parent is upstream", LibGit2.GitHash(p) == c3)
        end
        ln(io, "rebase! files", isfile(joinpath(wt, "local.txt")), isfile(joinpath(wt, "README.md")))
    catch e
        err(io, "rebase!", e)
    end
    close(repo3); close(up2)

    # errors: a repository that is not one, a missing remote
    try
        LibGit2.GitRepo(joinpath(W, "packages"))
        ln(io, "not a repo", "opened")
    catch e
        err(io, "not a repo", e)
    end
    try
        LibGit2.clone(joinpath(W, "nope"), joinpath(W, "nope-clone"); isbare = true)
        ln(io, "missing source", "cloned")
    catch e
        err(io, "missing source", e)
    end
end

function net_ops(io::IO, W::String)
    url = "https://github.com/JuliaLang/Example.jl.git"
    path = joinpath(W, "net", "Example")
    repo = LibGit2.clone(url, path; isbare = true, depth = 1)
    ln(io, "https clone depth=1", LibGit2.isshallow(repo))
    tree = LibGit2.revparseid(repo, "HEAD^{tree}")
    ln(io, "HEAD tree", tree)
    LibGit2.fetch(repo; remoteurl = url, refspecs = ["+refs/*:refs/remotes/cache/*"],
                  depth = LibGit2.Consts.FETCH_DEPTH_UNSHALLOW)
    ln(io, "unshallow", LibGit2.isshallow(repo))
    ln(io, "v0.5.4^{tree}", LibGit2.revparseid(repo, "v0.5.4^{tree}"))
    close(repo)
    # (a remote that asks for credentials differs by design: natively LibGit2's credential callback answers,
    # in Wasm there is none and libgit2's EAUTH error is the result; not compared here)
end

function main()
    W = ENV["WORK"]
    io = Core.stdout
    try
        local_ops(io, W)
        get(ENV, "NET", "0") == "1" && net_ops(io, W)
    catch e
        err(io, "UNCAUGHT", e)
    end
    return Int32(0)
end

end # module
