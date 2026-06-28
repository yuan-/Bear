#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Dogfooding harness entry point (Stage 2). One command spins up a per-project
# throwaway build container, runs the installed release Bear inside it against
# a pinned target, and passes/fails the captured compilation database against a
# committed golden (dogfood-golden-regression).
#
# Two validation modes, selected per-target by VALIDATION in config.env:
#   golden  (zlib, Stage 2): gate the capture against a committed golden CDB.
#   oracle  (curl, Stage 3): gate the capture against the database CMake itself
#           emits, on the intersection of translation units, via cdb-compare
#           (dogfood-oracle-cmake, dogfood-divergence-report).
#
# Three target-agnostic Stage 4 modes each build+capture once (twice, for
# determinism) and SKIP the golden/oracle gate:
#   --determinism   run the build twice and compare the two captures
#                   (dogfood-determinism). PASS iff equivalent; FAIL = real
#                   non-determinism / a race in Bear itself.
#   --invariants    assert structural invariants on the single capture with
#                   cdb-compare (dogfood-invariants): non-empty arguments, no
#                   true duplicates, and entry count within tolerance of the
#                   object files the build produced. PASS iff all hold; FAIL =
#                   a malformed CDB.
#   --replay[=N]    sample up to N entries (default 20) and replay each recorded
#                   command in its directory with -fsyntax-only, INSIDE the build
#                   container (dogfood-replay). PASS iff all sampled entries
#                   replay (>=1 verified); FAIL = a malformed entry; all-
#                   inconclusive = INCONCLUSIVE.
#
# Usage:
#   tests/dogfooding/run.sh [--label L] [--rebless] [--keep] [zlib|curl]
#   tests/dogfooding/run.sh --determinism [--inject-fault] [--label L] [--keep] T
#   tests/dogfooding/run.sh --invariants [--label L] [--keep] T
#   tests/dogfooding/run.sh --replay[=N] [--label L] [--keep] T
#   tests/dogfooding/selftest.sh    # no container: prove the checks catch faults
#
#   --label L       name the per-run results subdirectory (default: local)
#   --rebless       regenerate the committed golden from this run instead of
#                   gating against it (dogfood-golden-rebless; golden targets only)
#   --determinism   run the build twice and compare the two captures
#                   (dogfood-determinism); skips the golden/oracle gate
#   --invariants    assert structural invariants on one capture (dogfood-invariants)
#   --replay[=N]    replay up to N sampled entries in-container (dogfood-replay;
#                   default N=20; also accepts `--replay N`)
#   --inject-fault  with --determinism, perturb the SECOND build with an extra
#                   compiler flag so the captures legitimately diverge - a
#                   self-test that the determinism check catches a fault
#   --keep          keep the throwaway container(s) and scratch instead of removing
#   zlib|curl       target name (default: zlib)
#
# Outcomes / exit codes (dogfood-build-failure-taxonomy):
#   PASS=0  FAIL=1  INCONCLUSIVE=2  ERROR=3
# Runtime model: host-orchestrated rootless Podman (feasibility.md Option C).

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# shellcheck source=tests/dogfooding/lib.sh
. "$HERE/lib.sh"

# --- argument parsing --------------------------------------------------------

LABEL="local"
REBLESS=0
KEEP=0
DETERMINISM=0
INJECT_FAULT=0
INVARIANTS=0
REPLAY=0
REPLAY_COUNT=20
TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --label) shift; [ $# -gt 0 ] || finish ERROR "--label needs a value"; LABEL="$1" ;;
        --label=*) LABEL="${1#--label=}" ;;
        --rebless) REBLESS=1 ;;
        --determinism) DETERMINISM=1 ;;
        --inject-fault) INJECT_FAULT=1 ;;
        --invariants) INVARIANTS=1 ;;
        --replay) REPLAY=1 ;;
        --replay=*) REPLAY=1; REPLAY_COUNT="${1#--replay=}" ;;
        --keep) KEEP=1 ;;
        -h|--help)
            sed -n '4,54p' "$HERE/run.sh" >&2
            exit 0 ;;
        --*) finish ERROR "unknown option: $1" ;;
        *)
            # A bare integer right after --replay is its count (--replay N form).
            if [ "$REPLAY" -eq 1 ] && [ "$REPLAY_COUNT" = "20" ]; then
                case "$1" in
                    *[!0-9]*) ;;  # not a number: fall through to target handling
                    *) REPLAY_COUNT="$1"; shift; continue ;;
                esac
            fi
            if [ -n "$TARGET" ]; then finish ERROR "only one target supported, got extra: $1"; fi
            TARGET="$1" ;;
    esac
    shift
done
[ -n "$TARGET" ] || TARGET="zlib"

# --determinism, --invariants, and --replay are each a standalone Stage 4 check
# that builds+captures once (or twice, for determinism) and SKIPS the
# golden/oracle gate. They are mutually exclusive with each other and with
# --rebless (no golden is involved). --inject-fault is a self-test of
# --determinism only.
MODE_COUNT=$((DETERMINISM + INVARIANTS + REPLAY))
if [ "$MODE_COUNT" -gt 1 ]; then
    finish ERROR "--determinism, --invariants, and --replay are mutually exclusive"
fi
if [ "$MODE_COUNT" -ge 1 ] && [ "$REBLESS" -eq 1 ]; then
    finish ERROR "--rebless applies only to the default golden gate, not the Stage 4 checks"
fi
if [ "$INJECT_FAULT" -eq 1 ] && [ "$DETERMINISM" -eq 0 ]; then
    finish ERROR "--inject-fault is only meaningful with --determinism"
fi
case "$REPLAY_COUNT" in
    ''|*[!0-9]*) finish ERROR "--replay count must be a positive integer: '$REPLAY_COUNT'" ;;
esac
if [ "$REPLAY" -eq 1 ] && [ "$REPLAY_COUNT" -lt 1 ]; then
    finish ERROR "--replay count must be >= 1"
fi

# Both values become path segments and a container-name segment; reject anything
# that could traverse out of the harness tree or break a podman name.
case "$TARGET" in *[!A-Za-z0-9_-]*) finish ERROR "target must be [A-Za-z0-9_-]: '$TARGET'" ;; esac
case "$LABEL"  in *[!A-Za-z0-9_-]*) finish ERROR "label must be [A-Za-z0-9_-]: '$LABEL'" ;; esac

TARGET_DIR="$HERE/targets/$TARGET"
[ -d "$TARGET_DIR" ] || finish ERROR "unknown target '$TARGET' (no $TARGET_DIR)"

# shellcheck source=tests/dogfooding/targets/zlib/config.env
. "$TARGET_DIR/config.env"

# Per-target validation selector (dogfood-oracle-cmake). zlib's config predates
# this selector and omits it, so golden is the default; curl sets oracle.
VALIDATION="${VALIDATION:-golden}"
case "$VALIDATION" in
    golden|oracle) ;;
    *) finish ERROR "VALIDATION must be golden or oracle, got '$VALIDATION'" ;;
esac

GOLDEN="$HERE/goldens/$TARGET/compile_commands.json"
RESULTS_DIR="$HERE/results/$TARGET/$LABEL"
mkdir -p "$RESULTS_DIR"

# Image / container names derived from the Bear commit under test, so a stale
# cached image is never silently reused for a different Bear.
BEAR_SHA="$(cd "$REPO_ROOT" && git rev-parse --short HEAD)"
BASE_TAG="bear-dogfood-base:$BEAR_SHA"
TARGET_TAG="bear-dogfood-$TARGET:$BEAR_SHA"
CONTAINER="bear-dogfood-$TARGET-$LABEL-$$"
# Determinism runs the build twice, in two distinct fresh containers.
CONTAINER2="bear-dogfood-$TARGET-$LABEL-$$-2"

info "target=$TARGET label=$LABEL bear=$BEAR_SHA rebless=$REBLESS determinism=$DETERMINISM invariants=$INVARIANTS replay=$REPLAY replay_count=$REPLAY_COUNT inject_fault=$INJECT_FAULT keep=$KEEP"

# Cleanup of the throwaway container(s) unless --keep. Cached images are left in
# place (mentioned in the final report); the harness only removes what it spun
# up per run.
cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        info "--keep: leaving container(s) $CONTAINER $CONTAINER2 in place"
    else
        rm_container "$CONTAINER"
        rm_container "$CONTAINER2"
    fi
}
trap cleanup EXIT INT TERM

# === STEP 1: PREFLIGHT (dogfood-preflight) ===================================
# Fail fast with a clear diagnostic BEFORE creating any scratch, so a run never
# starts only to leave a torn container behind.

require_podman

preflight_disk "$MIN_FREE_KIB" || finish ERROR "disk preflight failed"
preflight_image "$BASE_IMAGE"  || finish ERROR "pinned base image unavailable: $BASE_IMAGE"

# The host comparator is the gate; check it now so a missing binary fails fast
# instead of after the multi-minute image builds and the real run.
CDB_COMPARE="$REPO_ROOT/target/release/cdb-compare"
if [ ! -x "$CDB_COMPARE" ]; then
    err "host cdb-compare not found at $CDB_COMPARE"
    err "build it with: cargo build --release -p bear-test-tools --bin cdb-compare"
    finish ERROR "host cdb-compare binary missing"
fi

# --rebless has no meaning for an oracle target (there is no committed golden;
# the reference is CMake's own database, regenerated each run).
if [ "$VALIDATION" = "oracle" ] && [ "$REBLESS" -eq 1 ]; then
    finish ERROR "--rebless applies only to golden targets; $TARGET validates against the CMake oracle"
fi

# === STEP 2: BUILD BASE IMAGE (dogfood-run-containerized) =====================
# Build Bear-under-test inside the base image from a 'git archive HEAD' context
# (committed files ONLY; the dirty working tree, plan.md, target/ never reach
# the image). A failure here is ERROR (harness / Bear build).

ARCHIVE_DIR="$(mktemp -d)"
cleanup_archive() { rm -rf "$ARCHIVE_DIR"; }
# Chain archive cleanup onto the container cleanup.
trap 'cleanup; cleanup_archive' EXIT INT TERM

info "exporting committed tree (git archive HEAD) to $ARCHIVE_DIR"
(cd "$REPO_ROOT" && git archive HEAD | tar -x -C "$ARCHIVE_DIR")

# 'git archive HEAD' inherently carries only committed files (never the dirty
# working tree, target/, or uncommitted scratch like plan.md). Assert positively
# that the harness itself made it in, rather than blocklisting scratch names that
# could one day be legitimately committed.
[ -f "$ARCHIVE_DIR/tests/dogfooding/run.sh" ] || \
    finish ERROR "git archive is missing tests/dogfooding (commit the harness before building)"

info "building base image $BASE_TAG"
if ! podman build \
        --build-arg "BASE_IMAGE=$BASE_IMAGE" \
        -f "$ARCHIVE_DIR/tests/dogfooding/base/Containerfile" \
        -t "$BASE_TAG" \
        "$ARCHIVE_DIR" >&2; then
    finish ERROR "base image build failed (Bear build or install)"
fi
cleanup_archive
trap cleanup EXIT INT TERM

# === STEP 3: BUILD TARGET IMAGE ==============================================
# FROM the locally-built base. dnf/curl/sha/network failures here are the
# target's own infra -> INCONCLUSIVE. A failure resolving the base would be
# ERROR, but step 2 just produced it, so a failure here is target infra.

# Each target pins its source under its own URL/SHA256 variable names (ZLIB_*,
# CURL_*); both Containerfiles consume the same SRC_DIR. Pass the variables the
# present target defines, so a target only ever sees its own build-args.
info "building target image $TARGET_TAG"
set -- --build-arg "BASE_TAG=$BASE_TAG" --build-arg "SRC_DIR=$SRC_DIR"
[ -n "${ZLIB_URL:-}" ]    && set -- "$@" --build-arg "ZLIB_URL=$ZLIB_URL"
[ -n "${ZLIB_SHA256:-}" ] && set -- "$@" --build-arg "ZLIB_SHA256=$ZLIB_SHA256"
[ -n "${CURL_URL:-}" ]    && set -- "$@" --build-arg "CURL_URL=$CURL_URL"
[ -n "${CURL_SHA256:-}" ] && set -- "$@" --build-arg "CURL_SHA256=$CURL_SHA256"
if ! podman build "$@" \
        -f "$TARGET_DIR/Containerfile" \
        -t "$TARGET_TAG" \
        "$TARGET_DIR" >&2; then
    finish INCONCLUSIVE "target image build failed (source fetch / sha / network / deps)"
fi

# === STEP 4: NON-EMPTY-CAPTURE SMOKE =========================================
# (dogfood-preflight + dogfood-run-containerized) Before the real build, prove
# interception actually works: a wrong libexec/INTERCEPT_LIBDIR layout makes
# Bear run yet capture nothing. Empty capture => ERROR.

info "smoke: verifying Bear captures a trivial compile"
SMOKE_OUT="$(podman run --rm --systemd=always "$TARGET_TAG" sh -c '
    set -e
    d="$(mktemp -d)"
    cd "$d"
    printf "int main(void){return 0;}\n" > smoke.c
    bear --output cc.json -- gcc -c smoke.c -o smoke.o >/dev/null 2>&1
    cat cc.json
' 2>/dev/null)" || SMOKE_OUT=""

case "$SMOKE_OUT" in
    *smoke.c*) info "smoke: capture OK" ;;
    *)
        err "smoke capture empty or missing smoke.c"
        err "diagnostic: libexec/INTERCEPT_LIBDIR mismatch: Bear ran but captured nothing"
        finish ERROR "non-empty-capture smoke failed (interception not working)"
        ;;
esac

# === STEP 5 (determinism): TWO REAL RUNS + COMPARE (dogfood-determinism) ======
# Stage 4 self-check, target-agnostic: run the SAME target's build twice in two
# fresh throwaway containers off the same pinned image, capture Bear's database
# from each, and compare the two captures. The fixed build paths (/src, /build)
# make the two captures multiset-equivalent, and cdb-compare is order-
# independent, so build parallelism is fine - NO normalization flags are needed.
# The build is its own reference: no golden, no oracle.
#
# PASS iff the two captures are equivalent. FAIL means real non-determinism / a
# race in Bear itself (the diff is saved). Either build failing for its own
# reasons is INCONCLUSIVE; infra/empty-capture is ERROR. All of that taxonomy
# lives in build_and_capture (lib.sh).
#
# --inject-fault is the self-test: it perturbs the SECOND build with an extra
# compiler flag (INJECT_CFLAGS, threaded into the build by config.env) so the
# two captures legitimately diverge and the check is shown to FAIL. We do NOT
# edit captured JSON by hand; the fault is a real, different second build.

if [ "$DETERMINISM" -eq 1 ]; then
    RUN1="$RESULTS_DIR/compile_commands.run1.json"
    RUN2="$RESULTS_DIR/compile_commands.run2.json"
    LOG1="$RESULTS_DIR/build.run1.log"
    LOG2="$RESULTS_DIR/build.run2.log"

    INJECT2=""
    if [ "$INJECT_FAULT" -eq 1 ]; then
        # A perturbing extra macro definition. config.env threads INJECT_CFLAGS
        # into the second build's compiler flags, so this lands in the recorded
        # arguments and makes run2 genuinely differ from run1.
        INJECT2="-DBEAR_DOGFOOD_INJECTED_FAULT=1"
        warn "inject-fault: second build perturbed with INJECT_CFLAGS='$INJECT2'"
    fi

    info "determinism run 1/2 (container $CONTAINER)"
    build_and_capture "$CONTAINER" "$RUN1" "$LOG1" ""
    info "determinism run 2/2 (container $CONTAINER2)"
    build_and_capture "$CONTAINER2" "$RUN2" "$LOG2" "$INJECT2"

    DIFF_HUMAN="$RESULTS_DIR/determinism-diff.txt"
    DIFF_JSON="$RESULTS_DIR/determinism-diff.json"

    info "comparing the two captures (cdb-compare compare, no normalization)"
    if "$CDB_COMPARE" compare "$RUN1" "$RUN2" >"$DIFF_HUMAN" 2>&1; then
        cat "$DIFF_HUMAN" >&2
        finish PASS "the two captures are equivalent (no non-determinism)"
    else
        cat "$DIFF_HUMAN" >&2
        "$CDB_COMPARE" compare --format json "$RUN1" "$RUN2" >"$DIFF_JSON" 2>&1 || true
        err "the two captures differ; diffs saved to $DIFF_HUMAN and $DIFF_JSON"
        finish FAIL "captures differ across two identical builds (Bear non-determinism) - see $DIFF_HUMAN"
    fi
fi

# === STEP 5 (invariants): ONE BUILD + STRUCTURAL INVARIANTS (dogfood-invariants)
# Stage 4 self-check: build+capture once, then assert structural invariants on
# the single capture with the host cdb-compare, and gate on its exit code. No
# golden, no oracle. The checks: non-empty-arguments and no-true-duplicates
# (always), plus entry-count against the number of object files the build
# actually produced (opt-in via --expected-objects).
#
# The object count is taken IN the container before teardown by a per-target
# OBJECT_COUNT_CMD (config.env): curl uses the default `find $OBJECTS_DIR -name
# '*.o' | wc -l` (its CMake objects persist), zlib counts make's dependency
# graph (`make -Bn`) because its in-tree build deletes its PIC objects. The
# count is written to /out/object_count, pulled out, and fed to
# --expected-objects with a per-target --tolerance band (OBJECT_TOLERANCE_PCT)
# so a stray build-system .o does not false-fail.
#
# PASS = invariants hold; FAIL = Bear produced a malformed CDB; build failure
# is INCONCLUSIVE and infra is ERROR (both handled in build_and_capture).

if [ "$INVARIANTS" -eq 1 ]; then
    FRESH="$RESULTS_DIR/compile_commands.json"
    BUILD_LOG="$RESULTS_DIR/build.log"
    OBJECTS_DIR="${OBJECTS_DIR:?config.env must set OBJECTS_DIR for invariants mode}"
    OBJ_TOL="${OBJECT_TOLERANCE_PCT:-10}"

    # Post-build step: count the object files the build PRODUCED and write the
    # number to /out/object_count. The instrument is per-target (OBJECT_COUNT_CMD
    # in config.env) because "objects produced" is not always "*.o files still on
    # disk": curl's CMake leaves every object under /build, so a `find` is exact
    # (the default below), but zlib's in-tree make deletes its PIC objects under
    # objs/ at link time, so a post-build find undercounts ~2x. zlib therefore
    # overrides OBJECT_COUNT_CMD to count make's own dependency graph
    # (`make -Bn`), a build-system-native, cleanup-independent, Bear-independent
    # count of produced objects. Default: count surviving *.o under OBJECTS_DIR.
    OBJECT_COUNT_CMD="${OBJECT_COUNT_CMD:-find \"$OBJECTS_DIR\" -name '*.o' 2>/dev/null | wc -l}"
    INV_POST="{ $OBJECT_COUNT_CMD ; } > /out/object_count 2>/dev/null"

    build_and_capture "$CONTAINER" "$FRESH" "$BUILD_LOG" "" "$INV_POST"

    OBJ_COUNT_FILE="$RESULTS_DIR/object_count"
    if ! podman cp "$CONTAINER:/out/object_count" "$OBJ_COUNT_FILE" >&2; then
        finish ERROR "could not copy object_count out of the container"
    fi
    OBJ_COUNT="$(tr -d ' \n\r\t' < "$OBJ_COUNT_FILE")"
    case "$OBJ_COUNT" in
        ''|*[!0-9]*) finish ERROR "object_count is not a number: '$OBJ_COUNT'" ;;
    esac
    if [ "$OBJ_COUNT" -eq 0 ]; then
        finish ERROR "object_count is 0 (find under $OBJECTS_DIR matched nothing); cannot gate entry-count"
    fi
    ENTRY_COUNT="$(grep -c '"file"' "$FRESH" 2>/dev/null || echo 0)"
    info "invariants: object_count=$OBJ_COUNT entry_count=$ENTRY_COUNT tolerance=${OBJ_TOL}%"

    REPORT="$RESULTS_DIR/invariants-report.txt"
    info "asserting structural invariants (cdb-compare invariants)"
    set +e
    "$CDB_COMPARE" invariants --drop-dependency-flags \
        --expected-objects "$OBJ_COUNT" --tolerance "$OBJ_TOL" \
        --format human "$FRESH" >"$REPORT" 2>&1
    INV_RC=$?
    set -e
    cat "$REPORT" >&2

    case "$INV_RC" in
        0) finish PASS "structural invariants hold (entries=$ENTRY_COUNT objects=$OBJ_COUNT); see $REPORT" ;;
        1) err "an invariant failed; see $REPORT"
           finish FAIL "Bear produced a malformed CDB (invariant violated) - see $REPORT" ;;
        *) finish ERROR "cdb-compare invariants failed to run (exit $INV_RC); see $REPORT" ;;
    esac
fi

# === STEP 5 (replay): ONE BUILD + REPLAY A SAMPLE (dogfood-replay) ============
# Stage 4 self-check: build+capture once, then take a sample of Bear's entries
# and replay each recorded command in its recorded directory with -fsyntax-only
# appended, verifying the compiler accepts the recorded arguments. This runs
# INSIDE the build container as part of the SAME podman run, because the
# recorded sources and generated headers exist there only before teardown. The
# replay loop (replay-loop.sh) is read into the in-container script; the
# in-image cdb-compare at /opt/bear/bin/cdb-compare drives the sampling.
#
# Categorization (per replay-loop.sh): OK / INCONCLUSIVE (missing generated
# header) / FAIL (malformed entry). Gate: any real FAIL => FAIL; all OK
# (inconclusive allowed) => PASS; every sampled entry inconclusive (nothing
# verified) => INCONCLUSIVE (do not pass vacuously).

if [ "$REPLAY" -eq 1 ]; then
    FRESH="$RESULTS_DIR/compile_commands.json"
    BUILD_LOG="$RESULTS_DIR/build.log"
    REPLAY_BUILD_DIR="${BUILD_DIR:?config.env must set BUILD_DIR for replay mode}"

    # Verify the in-image cdb-compare exists before relying on it.
    if ! podman run --rm "$TARGET_TAG" test -x /opt/bear/bin/cdb-compare; then
        finish ERROR "in-image cdb-compare missing at /opt/bear/bin/cdb-compare"
    fi

    # Build the in-container post-build snippet: the replay function definition
    # (from replay-loop.sh) followed by one call against Bear's capture. The
    # function writes its OK/FAIL/INCONCLUSIVE tally and any failing commands to
    # /out/replay_result; its return code is recorded to /out/replay_rc so the
    # host can gate on it without parsing JSON.
    [ -f "$HERE/replay-loop.sh" ] || finish ERROR "replay-loop.sh missing next to run.sh (commit the harness)"
    REPLAY_FN="$(cat "$HERE/replay-loop.sh")"
    REPLAY_POST="$REPLAY_FN
replay_cdb /opt/bear/bin/cdb-compare /out/compile_commands.json $REPLAY_COUNT \"$REPLAY_BUILD_DIR\" /out/replay_result
echo \$? > /out/replay_rc
cat /out/replay_result"

    build_and_capture "$CONTAINER" "$FRESH" "$BUILD_LOG" "" "$REPLAY_POST"

    REPLAY_RESULT="$RESULTS_DIR/replay_result"
    REPLAY_RC_FILE="$RESULTS_DIR/replay_rc"
    if ! podman cp "$CONTAINER:/out/replay_result" "$REPLAY_RESULT" >&2; then
        finish ERROR "could not copy replay_result out of the container"
    fi
    if ! podman cp "$CONTAINER:/out/replay_rc" "$REPLAY_RC_FILE" >&2; then
        finish ERROR "could not copy replay_rc out of the container"
    fi
    cat "$REPLAY_RESULT" >&2
    REPLAY_RC="$(tr -d ' \n\r\t' < "$REPLAY_RC_FILE")"
    TALLY="$(sed -n 's/^replay: //p' "$REPLAY_RESULT")"
    info "replay: $TALLY (build-dir $REPLAY_BUILD_DIR, sampled up to $REPLAY_COUNT)"

    case "$REPLAY_RC" in
        0) finish PASS "all sampled entries replayed (at least one verified): $TALLY" ;;
        1) err "a recorded command failed to replay (malformed entry); see $REPLAY_RESULT"
           finish FAIL "replay failed - a malformed entry was found ($TALLY); see $REPLAY_RESULT" ;;
        2) finish INCONCLUSIVE "every sampled entry was inconclusive (missing generated inputs); replay verified nothing ($TALLY)" ;;
        3) finish ERROR "in-container cdb-compare sample failed; replay could not start - see $REPLAY_RESULT" ;;
        *) finish ERROR "replay loop did not run to completion (rc='$REPLAY_RC'); see $REPLAY_RESULT" ;;
    esac
fi

# === STEP 5: REAL RUN (dogfood-run-containerized + dogfood-fixed-paths) =======
# Run the real build wrapped by Bear at fixed path /src. Configure/make failure
# => INCONCLUSIVE (target's own reasons). Empty captured CDB => ERROR. The
# build-and-capture body is shared with the determinism path (lib.sh).

FRESH="$RESULTS_DIR/compile_commands.json"
BUILD_LOG="$RESULTS_DIR/build.log"

build_and_capture "$CONTAINER" "$FRESH" "$BUILD_LOG" ""

# For oracle targets, also pull CMake's own database (the reference oracle the
# in-container build wrote to /out/oracle.json).
ORACLE="$RESULTS_DIR/oracle.json"
if [ "$VALIDATION" = "oracle" ]; then
    if ! podman cp "$CONTAINER:/out/oracle.json" "$ORACLE" >&2; then
        finish ERROR "could not copy oracle.json (CMake's database) out of the container"
    fi
    if ! grep -q '"file"' "$ORACLE" 2>/dev/null; then
        err "CMake oracle DB has no entries: $ORACLE"
        finish ERROR "empty CMake oracle database (configure did not export compile_commands)"
    fi
    info "captured oracle CDB: $ORACLE"
fi

# === STEP 6: GATE ============================================================
# Dispatch on the per-target validation selector: oracle (curl, Stage 3) or
# golden (zlib, Stage 2).

if [ "$VALIDATION" = "oracle" ]; then
    # --- oracle gate (dogfood-oracle-cmake, dogfood-divergence-report) -------
    # cdb-compare does the whole comparison; no jq, no allow-list file:
    #   --output-from-o         match TUs by absolute object path (directory + the
    #                           -o argument), so the two producers' differing
    #                           `output` encodings align and a source compiled
    #                           into several targets stays distinct.
    #   --drop-dependency-flags drop the benign `-M*` depfile flags the make-time
    #                           command carries but CMake's configure-time export
    #                           omits (the only difference on matched TUs).
    #   --substitute-compiler   absorb any compiler-driver path difference.
    #   --intersection          gate on matched-but-differing TUs only; entries on
    #                           just one side are advisory extras (the divergence
    #                           report), never a failure.
    # Exit 0 = matched TUs equivalent (PASS); 1 = real divergence OR a load error.
    REPORT="$RESULTS_DIR/oracle-report.txt"
    REPORT_JSON="$RESULTS_DIR/oracle-compare.json"
    NORM_FLAGS="--substitute-compiler cc --output-from-o --drop-dependency-flags"

    info "comparing Bear vs CMake on the TU intersection (cdb-compare)"
    set +e
    # shellcheck disable=SC2086  # NORM_FLAGS is a deliberate word list
    "$CDB_COMPARE" compare --intersection $NORM_FLAGS "$FRESH" "$ORACLE" >"$REPORT" 2>&1
    ORACLE_RC=$?
    # Archive a machine-readable copy of the three-set report (same normalization).
    # shellcheck disable=SC2086
    "$CDB_COMPARE" compare $NORM_FLAGS --format json "$FRESH" "$ORACLE" >"$REPORT_JSON" 2>/dev/null
    set -e

    # The `summary:` line is printed only when cdb-compare ran to completion in
    # --intersection mode; its absence means a load/parse error (cdb-compare exits
    # 1 for that too), so treat a missing summary as an infra ERROR, not a FAIL.
    SUMMARY="$(sed -n 's/^summary: //p' "$REPORT")"
    if [ -z "$SUMMARY" ]; then
        finish ERROR "cdb-compare did not produce an oracle comparison; see $REPORT"
    fi
    info "oracle: $SUMMARY"
    info "full divergence report: $REPORT (machine-readable: $REPORT_JSON)"

    # Non-vacuity / coverage floor: a zero-matched intersection compared nothing
    # (matching broken, or the inputs share no TUs) and must not pass. cdb-compare
    # is slated to enforce this itself; until then the harness refuses it.
    MATCHED="$(printf '%s' "$SUMMARY" | sed -n 's/^matched=\([0-9]*\) .*/\1/p')"
    if [ -z "$MATCHED" ] || [ "$MATCHED" -eq 0 ]; then
        finish ERROR "oracle matched 0 translation units - nothing was compared (matching broken?); see $REPORT"
    fi

    case "$ORACLE_RC" in
        0) finish PASS "matched TUs equivalent to the CMake oracle ($SUMMARY)" ;;
        1) err "oracle mismatch: matched TUs diverge from CMake's database"
           err "see the 'matched but differing' section of $REPORT (and $REPORT_JSON)"
           finish FAIL "oracle mismatch - matched TUs differ from the CMake oracle; see $REPORT" ;;
        *) finish ERROR "cdb-compare failed during the oracle comparison (exit $ORACLE_RC); see $REPORT" ;;
    esac
fi

# === STEP 6 (golden): GATE (dogfood-golden-regression) =======================
# Host cdb-compare gates the fresh CDB against the committed golden. On
# --rebless, write the golden instead (dogfood-golden-rebless).
#
# Per the resolved decision, no normalization flags are used: the same pinned
# image and fixed /src path make the raw multiset reproducible. If a benign
# compiler-path diff ever appears, add --substitute-compiler cc to BOTH the
# bless and the check below, consistently.

if [ "$REBLESS" -eq 1 ]; then
    info "reblessing golden: $GOLDEN"
    mkdir -p "$(dirname "$GOLDEN")"
    if ! "$CDB_COMPARE" normalize --sort "$FRESH" -o "$GOLDEN" >&2; then
        finish ERROR "cdb-compare normalize failed during rebless"
    fi
    info "golden rewritten from this run; review and commit it"
    finish PASS "reblessed golden at $GOLDEN"
fi

if [ ! -f "$GOLDEN" ]; then
    err "no golden at $GOLDEN; produce one with: $0 --rebless $TARGET"
    finish ERROR "missing golden (run --rebless first)"
fi

info "gating fresh CDB against golden"
DIFF_HUMAN="$RESULTS_DIR/golden-diff.txt"
DIFF_JSON="$RESULTS_DIR/golden-diff.json"

if "$CDB_COMPARE" compare "$GOLDEN" "$FRESH" >"$DIFF_HUMAN" 2>&1; then
    cat "$DIFF_HUMAN" >&2
    finish PASS "fresh CDB matches golden (no regression)"
else
    cat "$DIFF_HUMAN" >&2
    # Save a machine-readable diff alongside the human one for review.
    "$CDB_COMPARE" compare --format json "$GOLDEN" "$FRESH" >"$DIFF_JSON" 2>&1 || true
    err "golden mismatch; diffs saved to $DIFF_HUMAN and $DIFF_JSON"
    finish FAIL "fresh CDB differs from golden (regression) - see $DIFF_HUMAN"
fi
