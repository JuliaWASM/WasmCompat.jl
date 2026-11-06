// The WebAssembly features a WasmCodegen module needs from the JavaScript engine, and the ones this
// engine lacks. A test runner skips such a module with the gap named, rather than failing in an
// obscure way (or passing silently).
//
//   const gaps = engineGaps(module);   // [] or [{ feature, reason }]
//   if (gaps.length) { console.log('SKIP: ' + gaps.map((g) => g.reason).join('; ')); process.exit(77); }
//
// Every module needs WasmGC and exception handling (`try_table`). It needs JSPI
// (`WebAssembly.Suspending`/`promising`) when an import may suspend: the libgit2 module's
// (WasmHost's fetch, `wasm_host`), `julia_io`'s `poll`, and `julia_task` (`Config(tasks = :jspi)`).

import { runtime } from './wasi.mjs';

// (module (type $s (struct (field i32))) (func (result i32) (struct.get $s 0 (ref.cast (ref $s) (struct.new $s (i32.const 1))))))
const GC = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 9, 2, 95, 1, 127, 0, 96, 0, 1, 127, 3, 2, 1, 1, 10, 16, 1, 14, 0, 65,
  1, 251, 0, 0, 251, 22, 0, 251, 2, 0, 0, 11]);
// (module (tag $t) (func (block $l (try_table (catch_all $l) (throw $t)))))
const EH = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 13, 3, 1, 0, 0, 10, 16, 1, 14, 0, 2, 64,
  31, 64, 1, 2, 0, 8, 0, 11, 0, 11, 11]);

const engine = () => runtime === 'bun' ? `Bun ${globalThis.Bun.version} (JavaScriptCore)` :
  runtime === 'node' ? `Node ${process.version} (V8 ${process.versions.v8})` : 'this engine';

/** Whether an import of `module` may suspend, so that its exports must run through JSPI. */
export function needsJspi(module) {
  return WebAssembly.Module.imports(module).some((i) =>
    i.module === 'libgit2' || i.module === 'julia_task' || (i.module === 'julia_io' && i.name === 'poll'));
}

/** The features `module` (a WebAssembly.Module, or omitted: the baseline) needs and this engine lacks. */
export function engineGaps(module) {
  const gaps = [];
  if (!WebAssembly.validate(GC))
    gaps.push({ feature: 'gc', reason: `WasmGC (struct/array types, ref.cast): not in ${engine()}` });
  if (!WebAssembly.validate(EH))
    gaps.push({ feature: 'exceptions', reason: `exception handling (try_table): not in ${engine()}` });
  if (module && needsJspi(module) && (typeof WebAssembly.Suspending !== 'function' || typeof WebAssembly.promising !== 'function'))
    gaps.push({ feature: 'jspi', reason: `JSPI (WebAssembly.Suspending/promising), which this module's suspending imports need: not in ${engine()}` +
      (runtime === 'node' ? ' (Node 22: --experimental-wasm-jspi)' : '') });
  return gaps;
}
