#!/bin/bash
# check.sh NAME [HOST_EXTENSIONS]: compile test/wasm/NAME.jl's `Prog.main` with WasmCodegen (trim = :safe), run it
# on Node's WASI and natively, and diff the two outputs. Needs JULIA, NODE, and WCG_JS (WasmCodegen's js/ directory);
# the active project must have WasmCodegen, WasmCompat and the standard libraries the programs use.
set -u
D=$(cd "$(dirname "$0")" && pwd); n=$1; export EXT=${2:-}
O=${OUT:-$D/out}/$n; W=$O/work; mkdir -p $O
$JULIA --startup-file=no $D/build.jl $D/$n.jl $O/$n.wasm > $O/build.log 2>&1 || { tail -20 $O/build.log; exit 1; }
rm -rf $W; mkdir -p $W
WORK=$W $JULIA --startup-file=no -e "include(\"$D/$n.jl\"); rc = Prog.main(); print(\"\n[main returned \$rc]\n\")" > $O/native.txt 2>&1
rm -rf $W; mkdir -p $W
$NODE --no-warnings $D/run.mjs $O/$n.wasm $W WORK=$W > $O/wasm.txt 2>&1
diff $O/native.txt $O/wasm.txt && echo "$n: IDENTICAL" || echo "$n: DIFFERENT (see above)"
