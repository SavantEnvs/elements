#!/usr/bin/env bash
#
# mayhem/build.sh — build Elements' fuzz binary (sanitized, SanCov-instrumented) plus the clean
# elements-tx / elements-util used by mayhem/test.sh. Re-runnable and offline: no step fetches anything.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Fuzz targets shipped as Mayhem targets: /mayhem/fuzz_<name> hard-links /mayhem/fuzz (see select_target.cc).
TARGETS="addrman block block_deserialize decode_tx descriptor_parse key_io miniscript_string netaddress partially_signed_transaction_deserialize process_message psbt script_interpreter simplicity simplicity_tx transaction"

# Build dirs are gitignored by upstream's `/*build*`, so `git clean -ffdX` removes them.
OBJS="$SRC/build_mayhem_objs"
FUZZ_DIR="$SRC/build_fuzz"
TEST_DIR="$SRC/build_tests"
mkdir -p "$OBJS"

# A re-run may resolve the compiler differently than the image build did (the ccache pre-fill puts a wrapper
# first on PATH). CMake then wipes the cache and drops the -D options, so start such a build dir afresh.
reset_if_compiler_changed() {
  local cache="$1/CMakeCache.txt" want
  [ -f "$cache" ] || return 0
  want="$(command -v "$CXX")"
  grep -qx "CMAKE_CXX_COMPILER:[A-Z]*=$want" "$cache" || rm -rf "$1"
}
reset_if_compiler_changed "$FUZZ_DIR"
reset_if_compiler_changed "$TEST_DIR"

# 1) The fuzz binary. Project objects get $SANITIZER_FLAGS + DWARF 3 + SanCov (fuzzer-no-link, unconditionally,
#    so the fuzzed code is instrumented even with the empty sanitizer off-switch).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/select_target.cc -o "$OBJS/select_target.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OBJS/lsan_off.o"

FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -ftrivial-auto-var-init=pattern"
cmake -S . -B "$FUZZ_DIR" -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_CFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fuse-ld=lld $OBJS/select_target.o $OBJS/lsan_off.o" \
  -DBUILD_FOR_FUZZING=ON -DSANITIZERS=fuzzer -DENABLE_WALLET=OFF -DWITH_CCACHE=OFF
cmake --build "$FUZZ_DIR" -j"$MAYHEM_JOBS" --target fuzz

FUZZ_BIN="$FUZZ_DIR/bin/fuzz"
[ -x "$FUZZ_BIN" ] || { echo "fuzz binary missing: $FUZZ_BIN" >&2; exit 1; }
install -m 0755 "$FUZZ_BIN" /mayhem/fuzz
for t in $TARGETS; do
  ln -f /mayhem/fuzz "/mayhem/fuzz_$t"
done
# Fail the build if a shipped target name is not compiled into the binary.
PRINT_ALL_FUZZ_TARGETS_AND_ABORT=1 /mayhem/fuzz > "$OBJS/targets.txt"
for t in $TARGETS; do
  grep -qx "$t" "$OBJS/targets.txt" || { echo "fuzz target '$t' is not compiled in" >&2; exit 1; }
done

# 2) The standalone reproducer: the same objects plus upstream's own run-once main (PROVIDE_FUZZ_MAIN_FUNCTION in
#    fuzz.cpp), no libFuzzer runtime. Usage: FUZZ=<target> /mayhem/fuzz-standalone <input-file>
FUZZ_CPP_OBJ="src/test/fuzz/util/CMakeFiles/test_fuzz.dir/__/fuzz.cpp.o"
SA_OBJ="src/test/fuzz/util/CMakeFiles/test_fuzz.dir/__/fuzz_standalone.cpp.o"
FIRST_OBJ="src/test/fuzz/CMakeFiles/fuzz.dir/addition_overflow.cpp.o"
CC_CMD="$(ninja -C "$FUZZ_DIR" -t commands "$FUZZ_CPP_OBJ" | tail -1)"
LINK_CMD="$(ninja -C "$FUZZ_DIR" -t commands bin/fuzz | tail -1)"
case "$CC_CMD$LINK_CMD" in *"$FUZZ_CPP_OBJ"*"$FIRST_OBJ"*) ;; *) echo "cannot recover fuzz compile/link commands" >&2; exit 1;; esac
SA_CC="${CC_CMD//$FUZZ_CPP_OBJ/$SA_OBJ} -DPROVIDE_FUZZ_MAIN_FUNCTION"
SA_LINK="${LINK_CMD#: && }"
SA_LINK="${SA_LINK% && :}"
SA_LINK="${SA_LINK// -fsanitize=fuzzer / }"
SA_LINK="${SA_LINK/ $FIRST_OBJ/ $SA_OBJ $FIRST_OBJ}"
SA_LINK="${SA_LINK/ -o bin\/fuzz / -o bin/fuzz-standalone }"
( cd "$FUZZ_DIR" && eval "$SA_CC" && eval "$SA_LINK" )
install -m 0755 "$FUZZ_DIR/bin/fuzz-standalone" /mayhem/fuzz-standalone

# 3) The oracle build: elements-tx and elements-util with the project's NORMAL flags (no sanitizers,
#    no SanCov, default debug info), so mayhem/test.sh stays an honest functional oracle.
cmake -S . -B "$TEST_DIR" -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld $COVERAGE_FLAGS" \
  -DBUILD_TESTS=ON -DENABLE_WALLET=OFF -DWITH_CCACHE=OFF
cmake --build "$TEST_DIR" -j"$MAYHEM_JOBS" --target elements-tx elements-util
