#!/usr/bin/env bash
#
# mayhem/test.sh — RUN regalloc.rs's OWN unit-test suite that mayhem/build.sh already
# compiled (cargo test --no-run -p regalloc --lib, normal flags). This only RUNS the
# tests and maps `cargo test` output to a CTRF summary. The lib's tests assert concrete
# data-structure behavior (AVL-tree ordering/membership invariants over thousands of
# ops, union-find, sparse-set, reg-map round-trips) — known-answer style — so a PATCH
# that neuters the crate (e.g. makes a container a no-op / returns constants) FAILS here.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

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

# Run the already-built unit tests (build.sh compiled them with `cargo test --no-run`).
# No network / no recompilation of deps needed.
OUT="$(env -u RUSTFLAGS cargo test -p regalloc --lib -- --test-threads=1 2>&1)"
STATUS=$?
echo "$OUT"

# Aggregate every `test result:` line cargo prints (one per test binary).
PASSED=$(echo "$OUT" | sed -n 's/.*test result:.*\b\([0-9]\+\) passed.*/\1/p' | awk '{s+=$1} END{print s+0}')
FAILED=$(echo "$OUT" | sed -n 's/.*test result:.*\b\([0-9]\+\) failed.*/\1/p' | awk '{s+=$1} END{print s+0}')
IGNORED=$(echo "$OUT" | sed -n 's/.*test result:.*\b\([0-9]\+\) ignored.*/\1/p' | awk '{s+=$1} END{print s+0}')

# If cargo itself failed but we parsed no failures, treat it as a hard failure.
if [ "$STATUS" -ne 0 ] && [ "$FAILED" -eq 0 ]; then
  FAILED=1
fi
# Guard against a silent no-op (0 tests ran) being reported as success.
if [ "$PASSED" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  echo "ERROR: no tests ran — build.sh should have produced the test binaries" >&2
  FAILED=1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
