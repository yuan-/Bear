#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fault demonstration for the clang-consumer check (dogfood-clang-consumer exit
# criterion: "catches a deliberately broken entry"). Unlike the replay
# bad-directory fault - a host-side fixture in selftest.sh - this demo MUST run
# where clang exists, i.e. IN the build container, because the host has no
# compiler. It is therefore a small, clearly-labeled in-container one-off, run by
# the maintainer against the curl target image:
#
#   podman run --rm \
#       -v tests/dogfooding/consumer-loop.sh:/consumer-loop.sh:ro,Z \
#       -v tests/dogfooding/consumer-fault-demo.sh:/demo.sh:ro,Z \
#       bear-dogfood-curl:<tag> sh /demo.sh
#
# It builds curl (so the captured CDB, sources, and headers exist), takes a
# KNOWN-GOOD entry that the consumer accepts (OK), strips an `-I` that the TU
# needs to find a header, and shows the SAME consumer (consumer_cdb from
# consumer-loop.sh) now reports FAIL for that entry. No JSON is edited by hand
# beyond removing the one include flag; the fault is a real, broken database
# entry. Exit 0 iff the good entry was OK and the broken entry was caught (FAIL);
# non-zero otherwise (the demo itself failed to demonstrate the fault).
#
# It deliberately reuses consumer_cdb's exact categorization so the demo proves
# the SHIPPED check (not a bespoke probe) catches the fault. To feed
# consumer_cdb a single chosen entry, it writes a one-entry compile_commands.json
# into a scratch directory and points the loop at it.

set -eu

# shellcheck source=tests/dogfooding/consumer-loop.sh
. /consumer-loop.sh

CDB_COMPARE="${CDB_COMPARE:-/opt/bear/bin/cdb-compare}"
OUT_DIR="/out"
CDB="$OUT_DIR/compile_commands.json"

# Build curl with Bear if the capture is not already present (so the demo is
# runnable standalone). The TARGET_BUILD_CMD is intentionally NOT reproduced
# here; the caller is expected to have built, or we do a minimal build below.
if [ ! -f "$CDB" ]; then
    printf '== building curl so the capture, sources, and headers exist ==\n' >&2
    mkdir -p "$OUT_DIR"
    cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DCURL_USE_OPENSSL=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF \
        -DCURL_USE_LIBPSL=OFF -DCURL_USE_GSSAPI=OFF -DUSE_NGHTTP2=OFF \
        -DUSE_LIBIDN2=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DCURL_ZLIB=OFF \
        -DUSE_LIBRTMP=OFF -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON \
        -DBUILD_CURL_EXE=ON -DBUILD_SHARED_LIBS=ON >&2
    bear --output "$CDB" -- cmake --build /build >&2
fi

GOOD_DIR="$(mktemp -d)"
BAD_DIR="$(mktemp -d)"
RESULT_GOOD="$(mktemp)"
RESULT_BAD="$(mktemp)"
cleanup() { rm -rf "$GOOD_DIR" "$BAD_DIR" "$RESULT_GOOD" "$RESULT_BAD"; }
trap cleanup EXIT INT TERM

# Pick a known-good entry and write two one-entry databases: the original (good)
# and a copy with one needed `-I` stripped (bad). python3 is present in the
# fedora base; it edits JSON robustly without a shell here-string.
printf '== picking a known-good entry and stripping an -I it needs ==\n' >&2
python3 - "$CDB" "$GOOD_DIR/compile_commands.json" "$BAD_DIR/compile_commands.json" <<'PY' >&2
import json, sys, copy
cdb_path, good_out, bad_out = sys.argv[1], sys.argv[2], sys.argv[3]
db = json.load(open(cdb_path))

def args_of(e):
    return e.get("arguments")

# Choose an entry that (a) has a source-tree -I we can strip and (b) is a plain
# library TU. altsvc.c is a stable, dependency-light curl TU that needs the
# curl/*.h headers reached via -I/src/include (and -I/src/lib).
cand = None
for e in db:
    a = args_of(e)
    if not a:
        continue
    if e["file"].endswith("altsvc.c") and any(x.startswith("-I/src") for x in a):
        cand = e
        break
if cand is None:
    # Fallback: any entry with a /src include path.
    for e in db:
        a = args_of(e)
        if a and any(x.startswith("-I/src") for x in a):
            cand = e
            break
if cand is None:
    sys.stderr.write("no entry with a /src include path to strip; cannot demo\n")
    sys.exit(2)

good = copy.deepcopy(cand)
bad = copy.deepcopy(cand)
stripped = [x for x in args_of(bad) if x.startswith("-I/src")]
bad["arguments"] = [x for x in args_of(bad) if not x.startswith("-I/src")]
json.dump([good], open(good_out, "w"))
json.dump([bad], open(bad_out, "w"))
sys.stderr.write("entry: %s\n" % cand["file"])
sys.stderr.write("stripped -I flags: %s\n" % " ".join(stripped))
PY

# Run the SHIPPED consumer over each one-entry database (count 1).
printf '\n== consumer verdict on the GOOD entry (expect OK / PASS) ==\n' >&2
set +e
consumer_cdb "$CDB_COMPARE" "$GOOD_DIR/compile_commands.json" 1 /build "$RESULT_GOOD"
GOOD_RC=$?
set -e
sed 's/^/  /' "$RESULT_GOOD" >&2
GOOD_TALLY="$(sed -n 's/^consumer: //p' "$RESULT_GOOD")"

printf '\n== consumer verdict on the BROKEN entry (-I stripped; expect FAIL) ==\n' >&2
set +e
consumer_cdb "$CDB_COMPARE" "$BAD_DIR/compile_commands.json" 1 /build "$RESULT_BAD"
BAD_RC=$?
set -e
sed 's/^/  /' "$RESULT_BAD" >&2
BAD_TALLY="$(sed -n 's/^consumer: //p' "$RESULT_BAD")"

printf '\n== fault-demo result ==\n' >&2
printf 'good: rc=%s (%s)\n' "$GOOD_RC" "$GOOD_TALLY" >&2
printf 'bad:  rc=%s (%s)\n' "$BAD_RC" "$BAD_TALLY" >&2

# The demo succeeds iff the good entry passed (rc 0) AND the broken entry was
# caught as a FAIL (rc 1). Any other combination means the consumer did not
# distinguish a well-formed entry from a deliberately broken one.
if [ "$GOOD_RC" -eq 0 ] && [ "$BAD_RC" -eq 1 ]; then
    printf 'DEMO PASSED: the consumer accepts the good entry and FAILS the stripped-I entry\n' >&2
    exit 0
fi
printf 'DEMO FAILED: the consumer did not flip OK->FAIL on the stripped-I fault\n' >&2
exit 1
