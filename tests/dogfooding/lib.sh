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
