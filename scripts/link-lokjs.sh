#!/usr/bin/env bash
# Builds lokjs.js/.wasm: src/lokjs.c linked against the libraries of an unmodified LibreOffice
# WASM build. The flags mirror those LibreOffice uses for soffice itself (26.8:
# solenv/gbuild/platform/EMSCRIPTEN_INTEL_GCC.mk, com_GCC_defs.mk and desktop/Executable_soffice_bin.mk
# for --disable-gui with PROXY_TO_PTHREAD), plus the runtime helpers a JS client needs.
set -euo pipefail

CORE="$(cd "${1:?path to LibreOffice core}" && pwd)"
SRC="$(cd "$(dirname "$0")/.." && pwd)/src"
OUT="$(mkdir -p "${2:?output directory}" && cd "$2" && pwd)"
WORK="$(mktemp -d)"

LINKDEPS="$(find "$CORE/workdir" "$CORE/instdir" -name 'soffice*.linkdeps' | head -n 1)"
WD="$CORE/workdir"

COMMON=(-pthread -sUSE_PTHREADS=1 -sSUPPORT_LONGJMP=wasm -fwasm-exceptions -D_LARGEFILE64_SOURCE -D_LARGEFILE_SOURCE)

emcc "${COMMON[@]}" -O2 -I"$CORE/include" -c "$SRC/lokjs.c" -o "$WORK/lokjs.o"
OBJECTS=("$WORK/lokjs.o")

# soffice's export list (main, libreofficekit_hook*, UNO bridge entry points) plus ours.
cp "$WD/CustomTarget/desktop/soffice_bin-emscripten-exports/exports" "$WORK/exports"
{
  echo _malloc
  echo _free
  # the first lokjs_* name on every EMSCRIPTEN_KEEPALIVE line is the function being defined
  grep 'EMSCRIPTEN_KEEPALIVE' "$SRC/lokjs.c" | grep -oE 'lokjs_[a-z_]+' | awk '!seen[$0]++' | sed 's/^/_/'
} >> "$WORK/exports"

RUNTIME='["UTF16ToString","stringToUTF16","UTF8ToString","ccall","cwrap","addOnPreMain","addOnPostRun","registerType","throwBindingError","ClassHandle","HEAPU16","HEAPU32","HEAPU8","HEAP32","stringToUTF8","lengthBytesUTF8","FS"]'

# LOKJS_PROFILING_FUNCS=1 keeps function names in the wasm, for readable stacks in DevTools.
EXTRA_LINK=()
if [ "${LOKJS_PROFILING_FUNCS:-0}" = 1 ]; then EXTRA_LINK+=(--profiling-funcs); fi
# LOKJS_TRACE=1 adds src/lokjs-trace.c, which wraps LibreOffice entry points (linker --wrap).
if [ "${LOKJS_TRACE:-0}" = 1 ]; then
  emcc "${COMMON[@]}" -O2 -c "$SRC/lokjs-trace.c" -o "$WORK/lokjs-trace.o"
  OBJECTS+=("$WORK/lokjs-trace.o")
  EXTRA_LINK+=(-Wl,--wrap=soffice_main -Wl,--wrap=_ZN11Application7ExecuteEv)
fi

em++ "${COMMON[@]}" "${EXTRA_LINK[@]}" \
  -sTOTAL_MEMORY=1GB -sSTACK_SIZE=131072 -sDEFAULT_PTHREAD_STACK_SIZE=65536 \
  --bind -sFORCE_FILESYSTEM=1 -sWASM_BIGINT=1 -sERROR_ON_UNDEFINED_SYMBOLS=1 -sFETCH=1 \
  -sASSERTIONS=1 -sEXIT_RUNTIME=0 -sEXPORT_EXCEPTION_HANDLING_HELPERS \
  "-sEXPORTED_RUNTIME_METHODS=$RUNTIME" \
  -sPROXY_TO_PTHREAD=1 \
  -sEXPORTED_FUNCTIONS=@"$WORK/exports" \
  -Wl,--gc-sections -fno-stack-protector \
  --pre-js "$CORE/static/emscripten/environment.js" \
  --pre-js "$WD/CustomTarget/static/emscripten_fs_image/soffice.data.js.link" \
  --pre-js "$CORE/static/emscripten/script.js" \
  --post-js "$WD/CustomTarget/static/unoembind/bindings_uno.js" \
  --post-js "$CORE/static/emscripten/uno.js" \
  "${OBJECTS[@]}" \
  -Wl,--whole-archive "$WD/LinkTarget/StaticLibrary/libunoembind.a" -Wl,--no-whole-archive \
  -L"$CORE/instdir/program" -L"$WD/LinkTarget/Library" -L"$WD/LinkTarget/StaticLibrary" \
  -Wl,--start-group $(cat "$LINKDEPS") -Wl,--end-group \
  -o "$OUT/lokjs.js"

cp "$CORE"/instdir/program/soffice.data "$CORE"/instdir/program/soffice.data.js.metadata "$OUT/"
ls -lh "$OUT"
