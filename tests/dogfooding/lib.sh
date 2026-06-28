#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sourced helpers for the dogfooding harness: logging, outcome/exit-code
# constants, preflight checks, and podman wrappers. Keeping these here keeps
# run.sh readable. POSIX sh only; no bashisms.

# --- outcome / exit codes (dogfood-build-failure-taxonomy) -------------------
#
# PASS         = 0  golden regression check passed
# FAIL         = 1  regression: golden mismatch (a real behavioral change)
# INCONCLUSIVE = 2  the target build failed for its own reasons
#                   (configure/make/source-fetch/network/sha/OOM)
# ERROR        = 3  harness or Bear-infra failure (podman missing, disk/digest
#                   preflight, base build, empty capture)
EXIT_PASS=0
EXIT_FAIL=1
EXIT_INCONCLUSIVE=2
EXIT_ERROR=3

# --- logging (everything to stderr; stdout is reserved for data) -------------

log()  { printf '%s\n' "$*" >&2; }
info() { printf '[dogfood] %s\n' "$*" >&2; }
warn() { printf '[dogfood] WARN: %s\n' "$*" >&2; }
err()  { printf '[dogfood] ERROR: %s\n' "$*" >&2; }

# Print the single final status line and exit with the matching code. Takes
# the outcome name and a one-line reason.
finish() {
    _outcome="$1"
    _reason="$2"
    case "$_outcome" in
        PASS)         _code="$EXIT_PASS" ;;
        FAIL)         _code="$EXIT_FAIL" ;;
        INCONCLUSIVE) _code="$EXIT_INCONCLUSIVE" ;;
        ERROR)        _code="$EXIT_ERROR" ;;
        *)            _code="$EXIT_ERROR"; _outcome="ERROR" ;;
    esac
    printf '\n[dogfood] OUTCOME: %s (exit %s) - %s\n' "$_outcome" "$_code" "$_reason" >&2
    exit "$_code"
}

# --- podman wrappers ---------------------------------------------------------

require_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        err "podman not found on PATH"
        finish ERROR "podman is required but not installed"
    fi
}

# Remove a container if it exists; ignore errors (best-effort cleanup).
rm_container() {
    podman rm -f "$1" >/dev/null 2>&1 || true
}

# --- preflight (dogfood-preflight) -------------------------------------------

# (a) Free-disk check on the podman graphroot against a per-target minimum.
preflight_disk() {
    _min_kib="$1"
    _graphroot="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
    if [ -z "$_graphroot" ]; then
        err "could not determine podman graphroot"
        return 1
    fi
    # df -Pk: POSIX format, 1024-byte blocks. Field 4 is available blocks.
    _avail_kib="$(df -Pk "$_graphroot" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -z "$_avail_kib" ]; then
        err "could not read free disk for graphroot $_graphroot"
        return 1
    fi
    info "graphroot $_graphroot has ${_avail_kib} KiB free (need ${_min_kib} KiB)"
    if [ "$_avail_kib" -lt "$_min_kib" ]; then
        err "insufficient free disk on $_graphroot: ${_avail_kib} KiB < ${_min_kib} KiB"
        return 1
    fi
    return 0
}

# (b) Resolve/verify the pinned base image is present or pullable. Pull by
# digest is idempotent; a failure here means the pin is unreachable.
preflight_image() {
    _image="$1"
    if podman image exists "$_image" 2>/dev/null; then
        info "pinned base image already present: $_image"
        return 0
    fi
    info "pulling pinned base image: $_image"
    if ! podman pull "$_image" >&2; then
        err "could not pull pinned base image: $_image"
        return 1
    fi
    return 0
}

# --- build-and-capture (dogfood-run-containerized + dogfood-fixed-paths) ------
#
# Run the real target build wrapped by Bear in a fresh throwaway container and
# copy the captured compilation database out. Factored out of run.sh STEP 5 so
# the determinism check (dogfood-determinism) can invoke it twice, once per
# fresh container, without duplicating the build-failure taxonomy.
#
# Arguments:
#   $1  container name (must be unique; the caller registers it for cleanup)
#   $2  destination path for the captured compile_commands.json on the host
#   $3  build log path on the host
#   $4  value for INJECT_CFLAGS passed into the container (empty for a normal
#       run; a perturbing flag for the --inject-fault determinism self-test)
#   $5  optional post-build snippet run INSIDE the same container AFTER the
#       build, with `set +e` (so its own failing commands - e.g. replay's
#       deliberate failing compiles - do not abort the script). Empty for a
#       normal / determinism run, so those paths are byte-for-byte unchanged.
#       Used by invariants mode (write /out/object_count) and replay mode (run
#       the replay loop and write /out/replay_result), which both need the
#       container's source/object tree still present before teardown.
#
# Reads from the caller's environment: TARGET_TAG, TARGET_BUILD_CMD.
#
# Outcome taxonomy (calls finish, which exits the whole run):
#   container never started      -> ERROR  (host/cgroup/image infra)
#   build exited non-zero        -> INCONCLUSIVE (target's own configure/make)
#   capture missing / empty      -> ERROR  (interception produced nothing)
# On success it returns 0 and leaves the capture at $2.
build_and_capture() {
    _bac_container="$1"
    _bac_dest="$2"
    _bac_log="$3"
    _bac_inject="$4"
    _bac_post="${5:-}"

    info "running real build in container $_bac_container"
    set +e
    podman run --systemd=always --name "$_bac_container" \
        --env "INJECT_CFLAGS=$_bac_inject" \
        "$TARGET_TAG" sh -c "
        set -e
        mkdir -p /out
        $TARGET_BUILD_CMD
        # Post-build step (invariants/replay) runs without set -e so its own
        # expected failures do not abort the container; it writes result files
        # under /out that the caller pulls out and gates on.
        set +e
        $_bac_post
        :
    " >"$_bac_log" 2>&1
    _bac_rc=$?
    set -e

    if [ "$_bac_rc" -ne 0 ]; then
        # Distinguish a container that never started (host/cgroup/image infra =>
        # ERROR) from one that ran but whose build failed for its own reasons
        # (=> INCONCLUSIVE). If the container does not exist, podman run never
        # launched it.
        if ! podman container exists "$_bac_container" 2>/dev/null; then
            err "podman run never started the container; see $_bac_log"
            finish ERROR "podman run failed to start container (systemd/cgroup/image infra)"
        fi
        err "target build exited $_bac_rc; see $_bac_log"
        finish INCONCLUSIVE "target build failed (configure/make) - log at $_bac_log"
    fi

    # Copy the captured CDB out of the stopped container (sidesteps SELinux relabel).
    if ! podman cp "$_bac_container:/out/compile_commands.json" "$_bac_dest" >&2; then
        finish ERROR "could not copy compile_commands.json out of the container"
    fi

    # Empty / entry-less capture => ERROR (Bear ran but captured nothing).
    if ! grep -q '"file"' "$_bac_dest" 2>/dev/null; then
        err "captured CDB has no entries: $_bac_dest"
        finish ERROR "empty capture from real build (interception produced nothing)"
    fi
    info "captured CDB: $_bac_dest"
    return 0
}

# --- oracle validation (dogfood-oracle-cmake, dogfood-divergence-report) ------
#
# The oracle path compares Bear's capture against the database CMake emits, on
# the intersection of translation units. The WHOLE comparison - matching TUs by
# absolute object path (`--output-from-o`), dropping the benign `-M*` depfile
# flags (`--drop-dependency-flags`), bucketing one-sided entries as advisory
# extras and gating on matched-but-differing only (`--intersection`) - is done
# by the host cdb-compare (see run.sh STEP 6). No jq and no allow-list file: the
# equivalence logic lives in the unit-tested tests/tools crate, not in shell.
