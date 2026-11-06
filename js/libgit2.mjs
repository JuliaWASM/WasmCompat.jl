// The host's side of WasmCompat's LibGit2 backend (`WasmCompat.libgit2_config`): a program compiled
// with it imports libgit2 compiled to WebAssembly as the import module "libgit2", the exports of
// LibGit2_wasm_jll's standalone module (`WasmCompat.libgit2_module()`, `libgit2.wasm`).
//
// Unlike the PCRE2 module, libgit2 has imports of its own:
//   - WASI preview 1, for its filesystem: give it a WASI instance of its own (its fd table is bound
//     to its memory) over the *same* preopens, environment (HOME, XDG_CONFIG_HOME, GIT_*) and
//     directories as the program's, so both see one filesystem;
//   - `wasm_host.http_request`, WasmHost.jl's fetch import ("wasm-fetch 1"), for https remotes; it
//     suspends (JSPI), so the program's export that reaches git must run under
//     `WebAssembly.promising`. Response bodies go through files of `$WASMHOST_SPOOL`, which must be
//     in the libgit2 instance's environment and exist.
//
//   import { WASI } from 'node:wasi';
//   import { makeImports } from '<WasmHost.jl>/js/node/imports.mjs';
//   const wasi = new WASI({ version: 'preview1', preopens, env, returnOnExit: true });
//   const wasmHost = makeImports({ preopens });
//   const imports = { ...wasiImportObject(programWasi), ...(await libgit2Imports(fs.readFileSync(path), { wasi, wasmHost })) };
//   const instance = await WebAssembly.instantiate(programModule, imports);
//   await WebAssembly.promising(instance.exports.main)();
//
// Node 24: a node:wasi call that allocates while a JSPI stack is suspended-and-resumed can abort the
// process (`Check failed: isolate_->IsOnCentralStack()`); run Node with `--no-turbo-fast-api-calls`. (Bun: no flag.)
// One promising call at a time: libgit2's C stack is one region of its memory.

import { wasiImportObject, wasiInitialize } from './wasi.mjs';

/**
 * `{ libgit2: exports }` of a new, initialized instance of the libgit2 module (bytes, a Response or
 * a Module). `wasi` is node:wasi's `WASI` (Node's or Bun's, see `wasi.mjs`) or a browser shim's with
 * `wasiImport` and `initialize(instance)`; `wasmHost` has `imports` (`{ wasm_host: { http_request } }`) and `bindMemory(memory)`
 * (WasmHost's adapter), or is omitted for a program with only local repositories.
 */
export async function libgit2Imports(source, { wasi, wasmHost } = {}) {
  if (!wasi) throw new Error('libgit2Imports: the libgit2 module needs a WASI instance of its own (`wasi`)');
  const module = source instanceof WebAssembly.Module ? source :
    typeof Response !== 'undefined' && source instanceof Response ? await WebAssembly.compileStreaming(source) :
    await WebAssembly.compile(source);
  const noFetch = { wasm_host: { http_request: () => -1 } };   // (a response that is never valid: a GitError)
  const instance = await WebAssembly.instantiate(module, {
    ...wasiImportObject(wasi), ...(wasmHost ? wasmHost.imports : noFetch) });
  wasiInitialize(wasi, instance);
  wasmHost?.bindMemory(instance.exports.memory);
  const rc = instance.exports.lg2w_init();
  if (rc < 0) throw new Error(`libgit2 module: lg2w_init failed (${rc})`);
  return { libgit2: instance.exports };
}

/** Whether a program's module imports the libgit2 module. */
export function importsLibgit2(programModule) {
  return WebAssembly.Module.imports(programModule).some((i) => i.module === 'libgit2');
}
