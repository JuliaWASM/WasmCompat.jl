// node run.mjs MODULE.wasm WORKDIR [ENV=VAL ...]: runs the module's `main` on Node's WASI (preopened WORKDIR,
// the julia_regex and julia_io path imports if the module imports them), printing what it prints.
import fs from 'node:fs';
import { WASI } from 'node:wasi';
const [wasmPath, work, ...envs] = process.argv.slice(2);
const wcg = process.env.WCG_JS;
const env = Object.fromEntries(envs.map((s) => s.split(/=(.*)/s).slice(0, 2)));
env.PWD = work;
const wasi = new WASI({ version: 'preview1', args: ['prog'], env, preopens: { [work]: work }, returnOnExit: true });
const mod = new WebAssembly.Module(fs.readFileSync(wasmPath));
const libs = new Set(WebAssembly.Module.imports(mod).map((i) => i.module));
const imports = { ...wasi.getImportObject() };
const bind = [];
if (libs.has('julia_regex')) {
  const { makeJuliaRegex } = await import(`${wcg}/julia_regex.mjs`);
  const rx = makeJuliaRegex(); imports.julia_regex = rx.imports; bind.push(rx);
}
if (libs.has('julia_io')) {
  const { makeJuliaIOPaths } = await import(`${wcg}/julia_io.mjs`);
  const p = makeJuliaIOPaths({ preopens: [work] }); imports.julia_io = p.imports; bind.push(p);
}
const inst = await WebAssembly.instantiate(mod, imports);
for (const b of bind) b.bindMemory(inst.exports.memory);
wasi.initialize(inst);
const rc = inst.exports.main();
process.stdout.write(`\n[main returned ${rc}]\n`);
