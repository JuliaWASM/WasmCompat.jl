# Julia's LibGit2 in Wasm on libgit2 (WasmCompatLibGit2Ext; `LIBGIT2=1 check.sh git`), against native libgit2: the
# operations Pkg performs, through LibGit2's own API, on repositories this program makes in $WORK (fixed signatures,
# so every hash is the same in both runs): init/add!/commit, open, revparse and objects, trees and blobs, HEAD and
# branches, configuration, remotes, clone (local and file://), fetch with refspecs, checkout of a tree into a directory
# (Pkg's checkout_tree_to_path), isdirty, reset!, fast-forward merge!, rebase!, and libgit2's errors; strings with a NUL, and the
# modes of executable entries after a checkout, a dry run and a reset! (`check.sh git julia_io`: the host's modes).
# With NET=1, a shallow clone over https and an unshallow fetch, Pkg's way.
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

# The host's file modes are WasmCodegen's julia_io: without it `chmod` is ENOTSUP in Wasm and no file is
# executable, so the modes are tested (in both runs) only in a build with it. (check.sh's EXT, at the build and
# in the native run.)
const MODES = occursin("julia_io", get(ENV, "EXT", ""))

# a tree with an executable entry (run.sh, 100755) and plain.txt, and one with sub/other.sh (100755) too, as loose
# objects: `add!` records no mode in Wasm
const MODE_TREE = "8f4572600a1d338b3d283ba4f566903c38cc01e8"
const SUB_TREE = "46a6fb72a42c2d8ba0a23e157dbad233bdcd5623"
const MODE_OBJECTS = [
    SUB_TREE => "78012b294a4d55303430643034303033315128c849ccccd32ba92861d8b96781e409abd467d7c52f6cbbd5a618ef7af7e166a02273535385a2d23cbde20c062995565519e3e52c46963e937f771af37d12d97fd2c40008148a4b9318f85fbedaadbf4beeaad25dd5805bd398ed3f7bcc730400b8f02a1f",
    "0fe9eabb2fba1ed522dd2550da96033ff3489e41" => "78012b294a4d5530366330343030373555c82fc9482dd22bce609052695595315ece6264e933f977a731df2791fd270118a10e36",
    MODE_TREE => "78012b294a4d553037643034303033315128c849ccccd32ba92861d8b96781e409abd467d7c52f6cbbd5a618ef7af7e166a02273535385a2d23cbde20c062995565519e3e52c46963e937f771af37d12d97f12007ebd1dde",
    "1a2485251c33a70432394c93fb89330ef214bfc9" => "78014bcac94f523034605056d44fcaccd32fcee002002f8504e1",
    "b9bca019c83a65e6d717d0b6da86215f45dde1b3" => "78014bcac94f52306328c849cccce302001de10414"]

function checkout_into(repo::LibGit2.GitRepo, t::LibGit2.GitTree, out::String, strategy::Cuint)
    GC.@preserve out begin
        opts = LibGit2.CheckoutOptions(checkout_strategy = strategy, target_directory = Base.unsafe_convert(Cstring, out))
        return Int(LibGit2.checkout_tree(repo, t, options = opts))
    end
end

isexec(f::String) = filemode(f) & 0o100 != 0

# a callback that is null, as natively; a credential that was not used
function callback_ops(io::IO, W::String)
    up = joinpath(W, "up")
    repo = LibGit2.clone(up, joinpath(W, "clones", "null-certificate"); isbare = true,
                         callbacks = LibGit2.Callbacks(:certificate_check => (C_NULL, nothing)))
    ln(io, "clone with a null certificate_check", LibGit2.head_oid(repo))
    close(repo)
    # options that ask for nothing the module does not do: no proxy, and those of a checkout a bare clone does not run
    fetch_opts = LibGit2.FetchOptions(callbacks = LibGit2.RemoteCallbacks(certificate_check = C_NULL),
        proxy_opts = LibGit2.ProxyOptions(proxytype = LibGit2.Consts.PROXY_NONE, certificate_cb = C_NULL))
    repo = LibGit2.clone(up, joinpath(W, "clones", "no-proxy"),
                         LibGit2.CloneOptions(bare = 1, fetch_opts = fetch_opts, checkout_opts = LibGit2.CheckoutOptions(dir_mode = 0o700)))
    ln(io, "bare clone with no proxy and a dir_mode", LibGit2.isbare(repo), LibGit2.head_oid(repo))
    close(repo)
    p = LibGit2.CredentialPayload(allow_git_helpers = false)
    p.credential = LibGit2.UserPasswordCredential("user", "password")
    LibGit2.approve(p; shred = false)
    ln(io, "approve", p.credential !== nothing)
    LibGit2.reject(p; shred = false)
    ln(io, "reject", p.credential !== nothing)
end

function mode_ops(io::IO, W::String)
    # a string with a NUL is not a C string (the url comes first: no host path in the message)
    try
        LibGit2.clone("u\0p", joinpath(W, "nul"))
        ln(io, "NUL in a clone url", "accepted")
    catch e
        err(io, "NUL in a clone url", e)
    end
    up = LibGit2.GitRepo(joinpath(W, "up"))
    try
        LibGit2.add!(up, "a\0b")
        ln(io, "NUL in add!", "accepted")
    catch e
        err(io, "NUL in add!", e)
    end
    try
        LibGit2.fetch(up; remoteurl = joinpath(W, "up"), refspecs = ["+refs/*:refs/re\0motes/cache/*"])
        ln(io, "NUL in a refspec", "accepted")
    catch e
        err(io, "NUL in a refspec", e)
    end
    try
        LibGit2.with(c -> LibGit2.get(String, c, "core\0.bare"), LibGit2.GitConfig(up))
        ln(io, "NUL in a configuration key", "accepted")
    catch e
        err(io, "NUL in a configuration key", e)
    end
    close(up)

    dir = joinpath(W, "modes")
    repo = LibGit2.init(dir)
    for (h, hex) in MODE_OBJECTS
        f = joinpath(dir, ".git", "objects", h[1:2], h[3:end])
        mkpath(dirname(f))
        write(f, hex2bytes(hex))
    end
    t = LibGit2.GitTree(repo, MODE_TREE)
    out = joinpath(W, "modes-out")
    mkpath(out)
    exe = joinpath(out, "run.sh")
    dry = LibGit2.Consts.CHECKOUT_FORCE | LibGit2.Consts.CHECKOUT_DRY_RUN
    ln(io, "checkout of an executable entry", checkout_into(repo, t, out, LibGit2.Consts.CHECKOUT_FORCE))
    listing(io, out)
    if MODES
        ln(io, "run.sh is executable", isexec(exe), "plain.txt is not", !isexec(joinpath(out, "plain.txt")))
        # a dry run changes nothing: not the mode of a file that is there, and it writes no file
        chmod(exe, 0o600)
        ln(io, "dry run", checkout_into(repo, t, out, dry), "mode", string(filemode(exe) & 0o777; base = 8))
    else
        ln(io, "the modes of the files are not tested in this build (check.sh git julia_io)")
        ln(io, "dry run", checkout_into(repo, t, out, dry))
    end
    out2 = joinpath(W, "modes-dry")
    mkpath(out2)
    ln(io, "dry run into an empty directory", checkout_into(repo, t, out2, dry), length(readdir(out2)))
    # reset! --hard to a commit of that tree writes the work tree, also with a dry run for its checkout (libgit2's
    # hard reset is a forced checkout)
    c = LibGit2.commit(repo, "modes\n"; author = SIG, committer = SIG, tree_id = LibGit2.GitHash(t))
    LibGit2.reset!(repo, c, LibGit2.Consts.RESET_HARD)
    ln(io, "reset! to an executable entry", c, isfile(joinpath(dir, "run.sh")))
    if MODES
        ln(io, "run.sh is executable", isexec(joinpath(dir, "run.sh")))
        chmod(joinpath(dir, "run.sh"), 0o600)
        LibGit2.reset!(repo, LibGit2.GitObject(repo, "HEAD"), LibGit2.Consts.RESET_HARD;
                       checkout_opts = LibGit2.CheckoutOptions(checkout_strategy = dry))
        ln(io, "reset! with a dry run, mode", string(filemode(joinpath(dir, "run.sh")) & 0o777; base = 8))
    end
    # entries a checkout does not write (SAFE): a file missing from the directory is not recreated, and a file in
    # the place of an entry's directory stays
    rm(exe)
    ln(io, "safe checkout", checkout_into(repo, t, out, LibGit2.Consts.CHECKOUT_SAFE), "run.sh recreated", isfile(exe))
    symlink("run.sh", exe)
    ln(io, "safe checkout over a link to itself", checkout_into(repo, t, out, LibGit2.Consts.CHECKOUT_SAFE), islink(exe))
    t2 = LibGit2.GitTree(repo, SUB_TREE)
    c2 = LibGit2.commit(repo, "sub\n"; author = SIG, committer = SIG, tree_id = LibGit2.GitHash(t2), parent_ids = [c])
    LibGit2.reset!(repo, c2, LibGit2.Consts.RESET_HARD)
    ln(io, "reset! to an entry in a directory", c2, isfile(joinpath(dir, "sub", "other.sh")))
    MODES && ln(io, "sub/other.sh is executable", isexec(joinpath(dir, "sub", "other.sh")))
    rm(joinpath(dir, "sub"); recursive = true)
    write(joinpath(dir, "sub"), "a file\n")
    try
        ln(io, "safe checkout over a file in a directory's place", Int(LibGit2.checkout_tree(repo, t2)), read(joinpath(dir, "sub"), String))
    catch e
        err(io, "safe checkout over a file in a directory's place", e)
    end
    rm(joinpath(dir, "sub"))
    symlink("sub", joinpath(dir, "sub"))
    try
        ln(io, "safe checkout over a directory that is a link to itself", Int(LibGit2.checkout_tree(repo, t2)), islink(joinpath(dir, "sub")))
    catch e
        err(io, "safe checkout over a directory that is a link to itself", e)
    end
    close(t2)
    close(t); close(repo)
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
        mode_ops(io, W)
        callback_ops(io, W)
        get(ENV, "NET", "0") == "1" && net_ops(io, W)
    catch e
        err(io, "UNCAUGHT", e)
    end
    return Int32(0)
end

end # module
