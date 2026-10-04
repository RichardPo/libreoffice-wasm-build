#!/usr/bin/env bash
# Fails if lokjs.js does not expose what the JavaScript client needs.
set -euo pipefail

JS="${1:?path to lokjs.js}"
missing=0
check() {
  if grep -q "$2" "$JS"; then echo "ok       $1"; else echo "MISSING  $1"; missing=1; fi
}
for fn in _lokjs_state _lokjs_document_load _lokjs_paint_tile _lokjs_post_key _lokjs_post_mouse _lokjs_post_uno _malloc _free; do
  check "$fn" "Module\[\"$fn\"\]\|var $fn ="
done
for rt in HEAPU8 HEAP32 stringToUTF8 lengthBytesUTF8 UTF8ToString FS ccall; do
  check "$rt (runtime)" "Module\[\"$rt\"\]"
done
check "Embind UNO bindings (zetajs)" "uno_Type"
check "Module.lokCallback bridge" "lokCallback"
exit $missing
