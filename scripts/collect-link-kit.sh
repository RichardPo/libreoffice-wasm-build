#!/usr/bin/env bash
# Collects everything needed to link a program against a finished (unmodified) LibreOffice WASM
# build, so linking can run in another job or a later run without rebuilding LibreOffice:
#   - the libraries listed in soffice's .linkdeps (written by LibreOffice's own link rule)
#   - soffice's export list, the JS glue it links with (pre-js / post-js) and LOK headers
#   - soffice.data + metadata (the in-memory file system)
# Paths are kept absolute: the next job checks out to the same workspace path.
set -euo pipefail

CORE="$(cd "${1:?path to LibreOffice core}" && pwd)"
OUT="${2:?output .tar.zst}"
LIST="$(mktemp)"

LINKDEPS="$(find "$CORE/workdir" "$CORE/instdir" -name 'soffice*.linkdeps' | head -n 1)"
[ -n "$LINKDEPS" ] || { echo "no soffice .linkdeps found" >&2; exit 1; }
echo "linkdeps: $LINKDEPS"

# Library search path: LibreOffice's own output folders plus the -L directories in .linkdeps
# (external libraries such as ICU or libxml2 live in workdir/UnpackedTarball/*).
SEARCH=("$CORE/instdir/program" "$CORE/workdir/LinkTarget/Library" "$CORE/workdir/LinkTarget/StaticLibrary")
for tok in $(cat "$LINKDEPS"); do
  case "$tok" in -L*) SEARCH+=("${tok#-L}") ;; esac
done

{
  echo "$LINKDEPS"
  for tok in $(cat "$LINKDEPS"); do
    case "$tok" in
      -L*) ;;
      -l*)
        name="${tok#-l}"
        found=""
        for dir in "${SEARCH[@]}"; do
          if [ -f "$dir/lib$name.a" ]; then found="$dir/lib$name.a"; break; fi
        done
        if [ -n "$found" ]; then echo "$found"; else echo "  (from Emscripten: $tok)" >&2; fi
        ;;
      /*.a) echo "$tok" ;;
      *.a) echo "$CORE/$tok" ;;
      *) echo "  (flag $tok)" >&2 ;;
    esac
  done
  echo "$CORE/workdir/CustomTarget/desktop/soffice_bin-emscripten-exports/exports"
  echo "$CORE/workdir/LinkTarget/StaticLibrary/libunoembind.a"
  echo "$CORE/workdir/CustomTarget/static/unoembind/bindings_uno.js"
  echo "$CORE/workdir/CustomTarget/static/emscripten_fs_image/soffice.data.js.link"
  echo "$CORE/static/emscripten/environment.js"
  echo "$CORE/static/emscripten/script.js"
  echo "$CORE/static/emscripten/uno.js"
  find "$CORE/include/LibreOfficeKit" -name '*.h'
  find "$CORE/instdir/program" -maxdepth 1 -name 'soffice.data*'
} | sort -u > "$LIST"

missing=0
while read -r f; do
  [ -e "$f" ] || { echo "missing: $f" >&2; missing=1; }
done < "$LIST"
[ "$missing" -eq 0 ] || exit 1

echo "$(wc -l < "$LIST") files, $(du -ch $(cat "$LIST") | tail -n 1 | cut -f1) uncompressed"
sed 's#^/##' "$LIST" | tar -C / -cf - -T - | zstd -T0 -10 -o "$OUT"
ls -lh "$OUT"
