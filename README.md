# libreoffice-wasm-build

GitHub Actions build of **LibreOffice as WebAssembly for a browser client that draws the document
itself**. LibreOffice is built from an official tag **without any changes**; on top of it this repo
links `lokjs`, a small program that starts LibreOffice in LibreOfficeKit mode and gives
JavaScript a plain C API.

The result offers in one WASM module:

- **LibreOfficeKit (LOK):** tiles (`paintTile`), input (keys, mouse, IME) and callbacks
  (invalidated areas, cursor, selection, `.uno:` states, comments, ruler), the way Collabora
  Online uses LibreOffice;
- **the Embind UNO bridge** that [zetajs](https://github.com/allotropia/zetajs) builds on, for
  working with the document model from JavaScript. Since LibreOffice 26.2, LOK starts that bridge
  during its own initialisation (`initJsUnoScripting()` in `desktop/source/lib/init.cxx`, commit
  `0b10ff07`), so zetajs scripts in `Module.uno_scripts` load just as in a regular build.

## Why a separate program

LOK has to start LibreOffice itself (UNO, VCL, the main loop); it cannot attach to an
already running `soffice`. LibreOffice's own `soffice.js` therefore cannot be used for LOK, and
its sources are not touched here either. Instead `src/lokjs.c` has its own `main()`:

1. `SAL_LOK_OPTIONS=unipoll` (LOK without its own main thread);
2. `libreofficekit_hook_2()` initialises LibreOffice — and with it the zetajs scripts;
3. `runLoop()` hands LibreOffice's main loop to the browser's event loop (Emscripten
   `emscripten_set_main_loop`), on the same thread.

JavaScript on that thread then calls the `lokjs_*` functions between main-loop iterations, and
receives LOK callbacks in `Module.lokCallback(doc, type, payload)`. This is the same structure
Collabora uses for its WASM build (own `main()`, linked against LibreOffice's libraries).

LibreOffice's build writes the complete list of libraries for linking `soffice` to
`soffice.js.linkdeps`; `scripts/link-lokjs.sh` links `lokjs.c` against exactly that list, with
the same flags LibreOffice uses for `soffice` plus the runtime helpers a JS client needs
(`HEAPU8`, `HEAP32`, `stringToUTF8`, `lengthBytesUTF8`, `FS`).

## The workflow

| Job | |
| --- | --- |
| `core` | LibreOffice core at a tag (default `libreoffice-26.2.6.3`, see below), Emscripten 4.0.10, `--host=wasm32-local-emscripten --disable-gui --with-wasm-module=writer --with-package-format=emscripten`. Keeps a **link kit** as artifact (libraries, export list, JS glue, LOK headers, `soffice.data`). |
| `lokjs` | Compiles `src/lokjs.c`, links it against the link kit, checks the exports, publishes `lokjs.js`, `lokjs.wasm`, `soffice.data`, `soffice.data.js.metadata` as artifact and GitHub Release. |
| `continue` | If `core` reached its time budget (~4¾ h), the compiler cache is saved and a new run continues (up to `max_attempts`). A real build error stops the chain. |

```sh
# full build
gh workflow run build.yml -f lo_ref=libreoffice-26.2.6.3 -f wasm_module=writer
# only relink lokjs against the LibreOffice of an earlier run (minutes)
gh workflow run build.yml -f core_run_id=<run id>
```

## Which LibreOffice version

**26.2.x.** It is the first series in which LOK starts the JS UNO bridge, and it does not yet have
a change that breaks LOK's single-threaded ("unipoll") mode:

- In 26.8, `ImplSVMain()` (vcl/source/app/svmain.cxx) returns immediately when VCL is already
  initialised (commit "vcl: osx: clean up macOS nested ImplSVMain() hacks", 27 Feb 2026).
  In unipoll mode `lo_initialize()` has initialised VCL already, so `runLoop()` → `soffice_main()`
  returns at once: the desktop and the main loop never start, `main()` ends, and the SolarMutex
  stays held by a thread that no longer exists — every later LOK or UNO call blocks forever.
- 26.2 still runs `Application::Main()` in that case (`bWasInitVCL || InitVCL()`), as does
  Collabora's fork.

`src/lokjs.c` reports this situation (`lokjs_state() == -1`, "runLoop() returned" in the
console). `trace=true` links `src/lokjs-trace.c`, which logs `soffice_main()`'s result.

## Using lokjs from JavaScript

Serve the files with these headers (SharedArrayBuffer):

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

`lokjs.js` expects a global `Module` before it loads; `Module.uno_scripts` lists the scripts that
run on LibreOffice's thread (`zeta.js` first). In such a script:

```js
Module.lokReady = () => {                       // main loop is running
  const doc = Module.ccall('lokjs_document_load', 'number', ['string', 'string'],
                           ['file:///tmp/doc.odt', ''])
  Module.ccall('lokjs_initialize_for_rendering', null, ['number', 'string'], [doc, '{}'])
  Module.ccall('lokjs_register_callback', null, ['number'], [doc])
  const buf = Module._malloc(256 * 256 * 4)
  Module._lokjs_paint_tile(doc, buf, 256, 256, 0, 0, 3840, 3840)   // twips
  const pixels = Module.HEAPU8.slice(buf, buf + 256 * 256 * 4)    // BGRA, see lokjs_get_tile_mode
}
Module.lokCallback = (doc, type, payload) => { /* LibreOfficeKitEnums.h: LOK_CALLBACK_* */ }
```

Functions return strings allocated by LibreOffice; release those with `lokjs_free`.

## Licences

`src/lokjs.c`: MPL 2.0 (like LibreOffice). Workflow and scripts: MIT (see `LICENSE`).
LibreOffice itself: MPL 2.0, with parts under other licences; the release archives contain built
LibreOffice files.
