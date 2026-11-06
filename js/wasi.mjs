// Engine-neutral use of a `node:wasi` WASI instance, for the hosts of the import libraries
// (`pcre2.mjs`, `libgit2.mjs`) and the test runner. Node and Bun both provide `node:wasi`, with
// different surfaces:
//
// | | Node (22+) | Bun (1.x) |
// |---|---|---|
// | `wasiImport` | yes | yes |
// | `getImportObject()` | yes | no (`getImports(module)`) |
// | `initialize(instance)` | yes | no (`setMemory(memory)`, then the module's `_initialize`) |
// | `start(instance)` | yes | yes |
//
//   import { WASI } from 'node:wasi';
//   import { wasiImportObject, wasiInitialize } from './wasi.mjs';
//   const wasi = new WASI({ version: 'preview1', args, env, preopens, returnOnExit: true });
//   const instance = await WebAssembly.instantiate(module, { ...wasiImportObject(wasi), ... });
//   wasiInitialize(wasi, instance);

/** The JavaScript runtime: `'bun'`, `'deno'`, `'node'` or `'other'` (a browser, a worker). */
export const runtime = typeof globalThis.Bun !== 'undefined' ? 'bun' :
  typeof globalThis.Deno !== 'undefined' ? 'deno' :
  typeof globalThis.process?.versions?.node === 'string' ? 'node' : 'other';

/** `{ wasi_snapshot_preview1: … }` of a WASI instance: `getImportObject()` where it exists. */
export function wasiImportObject(wasi) {
  if (typeof wasi.getImportObject === 'function') return wasi.getImportObject();
  if (wasi.wasiImport) return { wasi_snapshot_preview1: wasi.wasiImport };
  throw new Error('wasiImportObject: this WASI instance has neither getImportObject() nor wasiImport');
}

/**
 * Initializes a reactor (a module that exports `memory` and maybe `_initialize`, not `_start`) for
 * its WASI instance, as node:wasi's `initialize` does: binds the memory, then runs `_initialize`.
 */
export function wasiInitialize(wasi, instance) {
  if (typeof wasi.initialize === 'function') return wasi.initialize(instance);
  const { memory, _initialize, _start } = instance.exports;
  if (!(memory instanceof WebAssembly.Memory)) throw new Error('wasiInitialize: the instance exports no memory');
  if (_start) throw new Error('wasiInitialize: the instance exports _start (a command, not a reactor)');
  if (typeof wasi.setMemory === 'function') wasi.setMemory(memory);
  else throw new Error('wasiInitialize: this WASI instance has neither initialize() nor setMemory()');
  _initialize?.();
}
