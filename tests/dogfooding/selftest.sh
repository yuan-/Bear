#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Dogfooding self-test: demonstrate that the Stage 4 checks catch the plan's
# injected faults - a dropped entry, a duplicated entry, an empty-arguments
# entry, and a corrupted `directory`. This is the demonstrable-fault-catching
# deliverable for the dogfood-invariants / dogfood-replay exit criterion.
#
# It needs NO container: it runs the HOST cdb-compare against tiny, committed
# fault fixtures under faults/, and runs the replay loop (replay-loop.sh, the
# very same function the in-container replay uses) against the bad-directory
# fixture. Every fault MUST be caught (the check must exit non-zero); if any
# fault slips through, the self-test fails.
#
# Usage:
#   tests/dogfooding/selftest.sh
#
# Exit 0 = every fault was caught; exit 1 = a fault was missed (or infra error).

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
FAULTS="$HERE/faults"

# shellcheck source=tests/dogfooding/replay-loop.sh
. "$HERE/replay-loop.sh"

CDB_COMPARE="$REPO_ROOT/target/release/cdb-compare"
if [ ! -x "$CDB_COMPARE" ]; then
    printf 'ERROR: host cdb-compare not found at %s\n' "$CDB_COMPARE" >&2
    printf 'build it with: cargo build --release -p bear-test-tools --bin cdb-compare\n' >&2
    exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0

# Assert that a command exits NON-zero (the fault was caught). $1 is a label;
# the rest is the command to run. Its output is shown indented for the log.
assert_caught() {
    _label="$1"
    shift
    if "$@" >/tmp/dogfood-selftest.$$ 2>&1; then
        printf 'MISS  %s (the check exited 0 - the fault was NOT caught)\n' "$_label" >&2
        sed 's/^/      /' /tmp/dogfood-selftest.$$ >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        printf 'CAUGHT %s\n' "$_label" >&2
        sed 's/^/      /' /tmp/dogfood-selftest.$$ >&2
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
    rm -f /tmp/dogfood-selftest.$$
}

printf '== dogfooding self-test: faults must be caught ==\n\n' >&2

# 1. Duplicated entry => no-true-duplicates invariant FAILS.
assert_caught "duplicate entry (no-true-duplicates)" \
    "$CDB_COMPARE" invariants --format human "$FAULTS/duplicate.json"
printf '\n' >&2

# 2. Empty arguments => non-empty-arguments invariant FAILS.
assert_caught "empty arguments (non-empty-arguments)" \
    "$CDB_COMPARE" invariants --format human "$FAULTS/empty-arguments.json"
printf '\n' >&2

# 3. Dropped entry => entry-count invariant FAILS (fewer entries than expected).
#    undercount.json has 2 entries; we state 3 expected with 0 tolerance.
assert_caught "dropped entry (entry-count, --expected-objects 3)" \
    "$CDB_COMPARE" invariants --expected-objects 3 --tolerance 0 \
        --format human "$FAULTS/undercount.json"
printf '\n' >&2

# 4. Corrupted directory => replay FAILS (the recorded `directory` does not
#    exist, so the compile can never run from where Bear claims it did).
#    replay_cdb returns non-zero on a real FAIL; assert_caught requires that.
REPLAY_OUT="$(mktemp)"
assert_caught "corrupted directory (replay)" \
    replay_cdb "$CDB_COMPARE" "$FAULTS/bad-directory.json" 1 /nonexistent "$REPLAY_OUT"
rm -f "$REPLAY_OUT"
printf '\n' >&2

# 5. Control: an honest 2-entry CDB with NO expected-count must PASS invariants
#    (a sanity check that the invariants do not false-fire on a clean input).
if "$CDB_COMPARE" invariants --format human "$FAULTS/undercount.json" >/dev/null 2>&1; then
    printf 'CONTROL OK  honest CDB passes invariants (no false positive)\n' >&2
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf 'CONTROL FAIL  honest CDB unexpectedly failed invariants\n' >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
printf '\n' >&2

printf '== self-test result: %s checks ok, %s failed ==\n' "$PASS_COUNT" "$FAIL_COUNT" >&2
if [ "$FAIL_COUNT" -gt 0 ]; then
    printf 'SELF-TEST FAILED: a fault was not caught (or a control misfired)\n' >&2
    exit 1
fi
printf 'SELF-TEST PASSED: every injected fault was caught\n' >&2
exit 0
