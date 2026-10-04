# libreoffice-wasm-build

GitHub Actions build of **headless LibreOffice as WebAssembly**, for a browser client that draws the
document itself. The build contains both:

- **LibreOfficeKit (LOK)**: tiles (`paintTile`), input (`postKeyEvent`, `postMouseEvent`) and
  callbacks (invalidated areas, cursor, selection, `.uno:` states, comments, ruler), like
  Collabora Online uses;
- **the Embind UNO bridge** that [zetajs](https://github.com/allotropia/zetajs) builds on, for
  working with the document model from JavaScript.

Since LibreOffice 26.2, LOK starts the JavaScript UNO bridge during its own initialisation
(`initJsUnoScripting()` in `desktop/source/lib/init.cxx`, commit `0b10ff07`, "Emscripten: Call
initJsUnoScripting also from LOKit"), so zetajs scripts in `Module.uno_scripts` load in a LOK build
just as they do in the Qt build. Older versions (25.8 and earlier) do not have this.

## What the workflow does

| Step | |
| --- | --- |
| Source | `LibreOffice/core` at a tag (default `libreoffice-26.8.1.1`), shallow clone |
| Toolchain | Emscripten 4.0.10 (the version LibreOffice's `static/README.wasm.md` uses) |
| Configure | `--host=wasm32-local-emscripten --disable-gui --with-wasm-module=writer --with-package-format=emscripten` (+ no Java, help, scripting frameworks, crash reporter) |
| Patch | `scripts/patch-exports.sh` exports the runtime helpers a LOK client needs (see below) |
| Build | `make`, with ccache through `EM_COMPILER_WRAPPER` |
| Output | `workdir/installation/LibreOffice/emscripten/` (`soffice.js`, `soffice.wasm`, `soffice.data`, …) as artifact and GitHub Release |

### Exported to JavaScript

LibreOffice already exports `_libreofficekit_hook` / `_libreofficekit_hook_2` (returns the
`LibreOfficeKit*`). Its function-pointer structs can only be used from JS with a few more runtime
helpers, which the patch adds:

| Export | Used for |
| --- | --- |
| `addFunction`, `removeFunction` (+ `ALLOW_TABLE_GROWTH`) | a JS function as C callback (`registerCallback`) |
| `getWasmTableEntry` | calling the function pointers in `LibreOfficeKitClass` / `LibreOfficeKitDocumentClass` |
| `HEAPU8`, `HEAP32` | reading structs and tile pixels |
| `stringToUTF8`, `lengthBytesUTF8` | passing URLs and JSON arguments |
| `FS` | putting documents into and out of the in-memory file system |

`scripts/check-exports.sh` verifies the result, including the Embind UNO bindings.

### Running for longer than 6 hours

A cold build takes longer than one GitHub-hosted job may run (4 cores). The build step therefore stops
itself after ~4¾ hours, the compiler cache is saved, and the workflow starts a new run (`attempt` + 1)
that continues from the cache. That repeats until the build is done or `max_attempts` (default 6) is
reached. A real build error stops the chain.

Start a build: **Actions → Build headless LibreOffice WASM → Run workflow**, or

```sh
gh workflow run build.yml -f lo_ref=libreoffice-26.8.1.1 -f wasm_module=writer
```

## Using the result

Serve the files with these headers (SharedArrayBuffer):

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

`soffice.js` expects a global `Module` before it loads; `Module.uno_scripts` lists the zetajs scripts
(`zeta.js` first). Initialising LOK and drawing tiles is the client's job; a sketch, not yet tested
against this build:

```js
// LibreOfficeKit* lok = libreofficekit_hook_2(install_path, user_profile_url)
const lok = Module._libreofficekit_hook_2(cstr('/instdir/program'), 0)
const cls = Module.HEAP32[lok >> 2]                       // LibreOfficeKitClass*
const fn = (struct, index) => Module.getWasmTableEntry(Module.HEAP32[(struct >> 2) + index])
// …documentLoad, initializeForRendering, registerCallback(addFunction(cb, 'viiii')), paintTile…
```

The member order of the structs is in `include/LibreOfficeKit/LibreOfficeKit.h` of the built
LibreOffice version (the first member of each class struct is `size_t nSize`).

## Licences

The workflow and scripts in this repository: MIT (see `LICENSE`). LibreOffice itself: MPL 2.0, with
parts under other licences; the release archives contain the built LibreOffice files.
