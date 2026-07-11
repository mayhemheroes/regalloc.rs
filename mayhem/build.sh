#!/usr/bin/env bash
#
# mayhem/build.sh — build regalloc.rs's cargo-fuzz targets as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus the project's
# own unit-test suite (normal flags) so mayhem/test.sh only RUNS it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# Toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE. The
# first (online) build populates $CARGO_HOME; the runtime sets CARGO_NET_OFFLINE=true
# for the re-run — so do NOT hard-code `--offline` here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# OSS-Fuzz Rust libFuzzer+ASan flags. ASan is applied via RUSTFLAGS (-Zsanitizer=address),
# NOT via the clang-oriented $SANITIZER_FLAGS (rustc ignores those). Honor the contract:
# if the override drops 'address' we drop the rust sanitizer to match.
SANITIZER_FLAGS="${SANITIZER_FLAGS-}"
case "$SANITIZER_FLAGS" in
  *address*|"") RUST_SANITIZER="-Zsanitizer=address" ;;  # default (ASan on, halting)
  *)            RUST_SANITIZER="" ;;                      # explicit no-sanitizer override
esac

# ── DWARF < 4 enforcement (§6.2 item 10) ───────────────────────────────────────
# Mayhem's triage can't read DWARF >= 4; the nightly's bundled LLVM defaults to DWARF 5.
export RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=3}"
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# Rust's ASan runtime archive is built with the bundled LLVM (DWARF 5) and links
# before the project code; strip its debug sections once (idempotent).
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name 'librustc-*_rt.asan.a' 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
    echo "Stripping debug info from Rust ASan runtime to enforce DWARF < 4: $ASAN_RT"
    objcopy --strip-debug "$ASAN_RT" || true
fi

export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing ${RUST_SANITIZER} ${RUST_DEBUG_FLAGS}"

# regalloc.rs ships its own cargo-fuzz crate (fuzz/) that builds under our nightly, so
# we use it as-is (upstream untouched — additive rule satisfied).
FUZZ_DIR="fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  # The fuzz crate is a member of the root minira-util workspace, so cargo-fuzz emits
  # into the SHARED workspace target dir ($SRC/target), not $SRC/fuzz/target. Check both.
  bin=""
  for cand in "$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t" "$SRC/target/$TRIPLE/release/$t"; do
    [ -x "$cand" ] && { bin="$cand"; break; }
  done
  [ -n "$bin" ] || { echo "ERROR: expected fuzz binary not found for $t (looked in $FUZZ_DIR/target and workspace target)" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t (from $bin)"
done

# Build the project's OWN unit test suite (the regalloc lib crate) with NORMAL flags,
# so mayhem/test.sh only RUNS it (honest, non-sanitized oracle for PATCH grading).
echo "=== building test suite (normal flags) ==="
env -u RUSTFLAGS cargo test --no-run -p regalloc --lib
echo "build.sh complete"
