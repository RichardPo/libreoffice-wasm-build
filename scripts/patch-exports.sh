#!/usr/bin/env bash
# Exports the Emscripten runtime helpers a JavaScript client needs to drive LibreOfficeKit:
#   addFunction/removeFunction  turn a JS function into a C function pointer (LOK callbacks)
#   getWasmTableEntry           call the function pointers in the LibreOfficeKit structs
#   HEAPU8/HEAP32               read tiles and structs from WASM memory
#   stringToUTF8/lengthBytesUTF8  pass strings (URLs, JSON arguments) to LOK
#   FS                          put documents into / take them out of the virtual file system
# addFunction needs a growable function table (ALLOW_TABLE_GROWTH).
set -euo pipefail

MK="${1:?path to solenv/gbuild/platform/EMSCRIPTEN_INTEL_GCC.mk}"
EXTRA='"addFunction","removeFunction","getWasmTableEntry","HEAPU8","HEAP32","stringToUTF8","lengthBytesUTF8","FS",'

grep -q 'EXPORTED_RUNTIME_METHODS=\[' "$MK" || { echo "EXPORTED_RUNTIME_METHODS not found in $MK" >&2; exit 1; }
if grep -q '"addFunction"' "$MK"; then
  echo "already patched"
  exit 0
fi
sed -i "s/-s EXPORTED_RUNTIME_METHODS=\[/-s ALLOW_TABLE_GROWTH=1 -s EXPORTED_RUNTIME_METHODS=[${EXTRA}/" "$MK"
grep -q '"addFunction"' "$MK" || { echo "patch did not apply" >&2; exit 1; }
grep -n 'EXPORTED_RUNTIME_METHODS' "$MK"
