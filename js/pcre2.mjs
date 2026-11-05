// The host's side of WasmCompat's PCRE2 backend (`WasmCompat.pcre2_config`): a program compiled
// with it imports PCRE2 compiled to WebAssembly as the import module "pcre2", the exports of
// PCRE2_wasm_jll's standalone module (`WasmCompat.pcre2_module()`, `libpcre2-8.wasm`), which
// imports nothing. Each instance of the program needs an instance of its own:
//
//   const imports = { ...wasi.getImportObject(), ...(await pcre2Imports(fs.readFileSync(path))) };
//   const instance = await WebAssembly.instantiate(programModule, imports);

/** `{ pcre2: exports }` of a new instance of the PCRE2 module (bytes, a Response or a Module). */
export async function pcre2Imports(source) {
  const module = source instanceof WebAssembly.Module ? source :
    typeof Response !== 'undefined' && source instanceof Response ? await WebAssembly.compileStreaming(source) :
    await WebAssembly.compile(source);
  const instance = await WebAssembly.instantiate(module, {});
  return { pcre2: instance.exports };
}

/** Whether a program's module imports the PCRE2 module. */
export function importsPcre2(programModule) {
  return WebAssembly.Module.imports(programModule).some((i) => i.module === 'pcre2');
}
