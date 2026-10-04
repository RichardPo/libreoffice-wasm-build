#!/usr/bin/env bash
# Fails if the built soffice.js does not expose what a LibreOfficeKit client needs.
set -euo pipefail

JS="${1:?path to soffice.js}"
missing=0
for sym in _libreofficekit_hook _libreofficekit_hook_2 addFunction getWasmTableEntry HEAPU8 stringToUTF8 FS; do
  if grep -q "Module\[\"${sym}\"\]\|Module\['${sym}'\]\|\"${sym}\"" "$JS"; then
    echo "ok       $sym"
  else
    echo "MISSING  $sym"
    missing=1
  fi
done
# The Embind UNO bridge that zetajs builds on:
if grep -q "uno_Type" "$JS"; then echo "ok       Embind UNO bindings"; else echo "MISSING  Embind UNO bindings"; missing=1; fi
exit $missing
