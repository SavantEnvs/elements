#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Oracle: upstream's own functional suite for the elements-tx / elements-util tools (test/util: golden
# hex/JSON output comparisons; binaries built by build.sh with normal flags), plus known-answer probes whose
# comparison happens in bash, where a neutered elements-tx cannot hide.
BIN="$SRC/build_tests/bin"
fail_early() { echo "$1" >&2; emit_ctrf "elements-util-test-runner" 0 1; exit 1; }
for b in elements-tx elements-util; do
  [ -x "$BIN/$b" ] || fail_early "missing $BIN/$b (build.sh should have built it)"
done
[ -e "$SRC/test/config.ini" ] || fail_early "missing test/config.ini (written by build.sh's configure step)"

out="$(python3 test/util/test_runner.py -v 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -15
passed=$(printf '%s\n' "$out" | grep -c 'PASSED:' || true)
failed=$(printf '%s\n' "$out" | grep -c 'FAILED:' || true)
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
# the suite has ~100 cases; far fewer means the runner did not really run them
if [ "$passed" -lt 100 ]; then echo "only $passed util cases passed (expected >= 100)" >&2; failed=$((failed + 1)); fi

kat() { # kat <description> <expected> <actual>
  if [ "$2" = "$3" ]; then passed=$((passed + 1)); else echo "KAT FAILED: $1: expected '$2' got '$3'" >&2; failed=$((failed + 1)); fi
}
kat "blank v1 tx" "01000000000000000000" \
  "$("$BIN/elements-tx" -serialization=BITCOIN -chain=main -create nversion=1 2>&1)"
kat "one input, one address output, one data output" \
  "02000000011f5c38dfcf6f1a5f5a87c416076d392c87e6d41970d5ad5e477a02d66bde97580000000000ffffffff0280a81201000000001976a9141fc11f39be1729bf973a7ab6a615ca4729d6457488ac0000000000000000526a4c4f54686973204f505f52455455524e207472616e73616374696f6e206f7574707574207761732063726561746564206279206d6f646966696564206372656174657261777472616e73616374696f6e2e00000000" \
  "$("$BIN/elements-tx" -serialization=BITCOIN -chain=main -create \
      in=5897de6bd6027a475eadd57019d4e6872c396d0716c4875a5f1a6fcfdf385c1f:0 \
      outaddr=0.18:13tuJJDR2RgArmgfv6JScSdreahzgc4T6o \
      outdata=54686973204f505f52455455524e207472616e73616374696f6e206f7574707574207761732063726561746564206279206d6f646966696564206372656174657261777472616e73616374696f6e2e 2>&1)"
kat "elements-util version banner" "Elements Core bitcoin-util utility version" \
  "$("$BIN/elements-util" --version 2>&1 | head -1 | sed 's/ v[0-9].*//')"

emit_ctrf "elements-util-test-runner" "$passed" "$failed"
