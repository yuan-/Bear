# SPDX-License-Identifier: GPL-3.0-or-later
#
# The replay loop (dogfood-replay), factored into a single POSIX sh function so
# the exact same logic runs in two places:
#   - INSIDE the build container (run.sh's replay mode reads this file into the
#     `podman run sh -c` script, because the recorded sources and generated
#     headers only exist there before teardown), and
#   - on the HOST in selftest.sh, against the committed bad-directory fault
#     fixture, to demonstrate the check catches a corrupted `directory`.
#
# It is sourced (host) or concatenated into the in-container script (container);
# either way it defines one function and runs nothing on its own.
#
# replay_cdb <cdb-compare> <CDB> <count> <build-dir> <summary-out>
#
#   <cdb-compare>  path to the cdb-compare binary to use for `sample`
#   <CDB>          compilation database to replay from
#   <count>        max entries to sample
#   <build-dir>    passed to `sample --build-dir` so the sampler prefers TUs
#                  whose flags do not reference build-dir includes
#   <summary-out>  file to write the OK/FAIL/INCONCLUSIVE tally and any failing
#                  commands to
#
# Each sampled entry is replayed in its recorded `directory` with `-fsyntax-only`
# appended (parse the TU, produce no object). Categorization:
#   OK            the compiler accepted the recorded arguments
#   INCONCLUSIVE  the failure is a missing include / generated header (the TU
#                 depends on a build-time input that no longer exists in a
#                 throwaway container) - not a Bear fault
#   FAIL          any other replay failure, including a `directory` that does
#                 not exist (a corrupted-directory fault) - a malformed entry
#
# Exit status: 0 iff no real FAIL AND at least one entry was actually verified
# (an all-INCONCLUSIVE sample validated nothing and must not pass vacuously,
# mirroring the oracle's non-vacuity stance). Return codes: 0 PASS, 1 a real
# FAIL, 2 all-inconclusive (INCONCLUSIVE), 3 `cdb-compare sample` itself failed
# (an infra ERROR). The caller maps these to the harness outcome.
replay_cdb() {
    _rc_compare="$1"
    _rc_cdb="$2"
    _rc_count="$3"
    _rc_builddir="$4"
    _rc_out="$5"

    _rc_ok=0
    _rc_fail=0
    _rc_incon=0
    : >"$_rc_out"

    "$_rc_compare" sample "$_rc_cdb" --count "$_rc_count" --build-dir "$_rc_builddir" \
        >"$_rc_out.lines" 2>>"$_rc_out"
    _rc_sample_rc=$?
    # A non-zero sample is an infra failure (a broken/malfunctioning cdb-compare),
    # NOT a vacuous "nothing matched": signal it distinctly (return 3 => ERROR)
    # rather than letting an empty line set fall through to INCONCLUSIVE.
    if [ "$_rc_sample_rc" -ne 0 ]; then
        printf 'ERROR: cdb-compare sample failed (rc=%s)\n' "$_rc_sample_rc" >>"$_rc_out"
        rm -f "$_rc_out.lines"
        return 3
    fi
    while IFS= read -r _rc_line; do
        [ -n "$_rc_line" ] || continue
        eval "set -- $_rc_line"
        _rc_dir="$1"
        shift
        # A nonexistent recorded `directory` is itself a malformed entry: the
        # compile can never run from where Bear claims it did. Categorize that
        # as a real FAIL before attempting the compile.
        if [ ! -d "$_rc_dir" ]; then
            _rc_fail=$((_rc_fail + 1))
            printf 'FAIL (bad directory "%s"): %s\n' "$_rc_dir" "$*" >>"$_rc_out"
            continue
        fi
        _rc_err="$( (cd "$_rc_dir" && "$@" -fsyntax-only) 2>&1 )"
        _rc_status=$?
        if [ "$_rc_status" -eq 0 ]; then
            _rc_ok=$((_rc_ok + 1))
            continue
        fi
        # Missing include / generated header => inconclusive (a build-time input
        # gone after teardown), NOT a malformed-entry failure. The signal is a
        # missing-file diagnostic ("No such file", "file not found", "not
        # found"); a bare "fatal error:" without one is a real failure, so it
        # is NOT matched here.
        case "$_rc_err" in
            *"No such file"*|*"file not found"*|*"not found"*)
                _rc_incon=$((_rc_incon + 1))
                printf 'INCONCLUSIVE (missing input): %s\n' "$*" >>"$_rc_out"
                ;;
            *)
                _rc_fail=$((_rc_fail + 1))
                printf 'FAIL: %s\n' "$*" >>"$_rc_out"
                printf '  stderr: %s\n' "$_rc_err" >>"$_rc_out"
                ;;
        esac
    done <"$_rc_out.lines"
    rm -f "$_rc_out.lines"

    printf 'replay: ok=%s fail=%s inconclusive=%s\n' \
        "$_rc_ok" "$_rc_fail" "$_rc_incon" >>"$_rc_out"

    if [ "$_rc_fail" -gt 0 ]; then
        return 1
    fi
    if [ "$_rc_ok" -eq 0 ]; then
        # Nothing was actually verified (all inconclusive, or empty sample).
        return 2
    fi
    return 0
}
