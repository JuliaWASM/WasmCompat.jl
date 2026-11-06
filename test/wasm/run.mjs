// node|bun run.mjs MODULE.wasm WORKDIR [ENV=VAL ...]: runs the module's `main` on node:wasi, Node's or Bun's (preopened WORKDIR,
// the julia_regex and julia_io path imports if the module imports them, and the PCRE2 module, `libpcre2-8.wasm`
// beside MODULE.wasm or $PCRE2_WASM, if it imports "pcre2"; the libgit2 module, `libgit2.wasm` beside MODULE.wasm or
// $LIBGIT2_WASM, if it imports "libgit2", with a WASI instance of its own over the same preopens and environment and,
// with $WASMHOST_JS (WasmHost.jl's js/node), WasmHost's fetch import for https; then `main` runs through JSPI),
// printing what it prints. A module needing a feature the engine lacks (js/engine.mjs) exits 77, printing
// `SKIP: <the gap>`.
import fs from 'node:fs';
import path from 'node:path';
import { pcre2Imports } from '../../js/pcre2.mjs';
import { libgit2Imports } from '../../js/libgit2.mjs';
import { WASI } from 'node:wasi';
import { wasiImportObject, wasiInitialize } from '../../js/wasi.mjs';
import { engineGaps } from '../../js/engine.mjs';
const [wasmPath, work, ...envs] = process.argv.slice(2);
const wcg = process.env.WCG_JS;
const env = Object.fromEntries(envs.map((s) => s.split(/=(.*)/s).slice(0, 2)));
env.PWD = work;
if (process.env.HOME) env.HOME = process.env.HOME;  // (the home directory, for paths shown as ~/...)
const wasi = new WASI({ version: 'preview1', args: ['prog'], env, preopens: { [work]: work }, returnOnExit: true });
// (a feature this engine lacks: exit 77 with the gap named, which check.sh reports as a skip)
const skip = (gaps) => { if (gaps.length) { process.stdout.write(`SKIP: ${gaps.map((g) => g.reason).join('; ')}\n`); process.exit(77); } };
skip(engineGaps());
const mod = new WebAssembly.Module(fs.readFileSync(wasmPath));
skip(engineGaps(mod));
const libs = new Set(WebAssembly.Module.imports(mod).map((i) => i.module));
const imports = { ...wasiImportObject(wasi) };
const bind = [];
if (libs.has('julia_regex')) {
  const { makeJuliaRegex } = await import(`${wcg}/julia_regex.mjs`);
  const rx = makeJuliaRegex(); imports.julia_regex = rx.imports; bind.push(rx);
}
if (libs.has('pcre2')) {
  const file = process.env.PCRE2_WASM ?? path.join(path.dirname(wasmPath), 'libpcre2-8.wasm');
  Object.assign(imports, await pcre2Imports(fs.readFileSync(file)));
}
let jspi = false;
if (libs.has('libgit2')) {
  const file = process.env.LIBGIT2_WASM ?? path.join(path.dirname(wasmPath), 'libgit2.wasm');
  const genv = { ...env };
  let wasmHost;
  if (process.env.WASMHOST_JS) {
    genv.WASMHOST_SPOOL = path.join(work, '.wasmhost');
    fs.mkdirSync(genv.WASMHOST_SPOOL, { recursive: true });
    const { makeImports } = await import(`${process.env.WASMHOST_JS}/imports.mjs`);
    wasmHost = makeImports({ preopens: { [work]: work } });
  }
  const gwasi = new WASI({ version: 'preview1', args: ['libgit2'], env: genv, preopens: { [work]: work }, returnOnExit: true });
  Object.assign(imports, await libgit2Imports(fs.readFileSync(file), { wasi: gwasi, wasmHost }));
  jspi = true;
}
if (libs.has('julia_io')) {
  const { makeJuliaIOPaths } = await import(`${wcg}/julia_io.mjs`);
  const p = makeJuliaIOPaths({ preopens: [work] }); imports.julia_io = p.imports; bind.push(p);
}
const inst = await WebAssembly.instantiate(mod, imports);
for (const b of bind) b.bindMemory(inst.exports.memory);
wasiInitialize(wasi, inst);
const rc = jspi ? await WebAssembly.promising(inst.exports.main)() : inst.exports.main();
process.stdout.write(`\n[main returned ${rc}]\n`);
