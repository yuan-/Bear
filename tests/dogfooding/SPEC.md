# Dogfooding harness specification - Stages 2 and 3

These are the `dogfood-*` contracts the harness under `tests/dogfooding/`
satisfies. They are contracts on the TEST HARNESS, not on Bear, so they
intentionally live here and NOT under `docs/requirements/` (which is reserved
for Bear's own contracts). They are condensed from the staged plan; the plan is
the source of intent, this file is the implemented spec.

Scope: non-automated, run by the maintainer at release time. Bear's installed
release binaries are run against a real project inside a throwaway container,
and the captured compilation database is validated. Sources and toolchain live
only in the container, never in the repo or the devcontainer image
(feasibility.md Option C). A per-target `VALIDATION` selector in `config.env`
chooses the validation mode: `golden` (Stage 2, zlib) gates against a committed
golden; `oracle` (Stage 3, curl) gates against the database CMake itself emits.

## dogfood-run-containerized

The suite builds a real project inside a throwaway container using the
installed, release Bear binaries, leaving the repo working tree and the
devcontainer image unmodified. A release/install build is required (not a debug
tree) so `libexec.so` sits at the path the binary resolves via
`INTERCEPT_LIBDIR`; a mismatch makes Bear run but capture nothing, so the
harness verifies interception actually occurred (non-empty capture) before
trusting a run.

Implementation: Bear is built inside the base image from `git archive HEAD`
(committed files only) and installed with `scripts/install.sh` to `PREFIX=/opt/bear`
(default `INTERCEPT_LIBDIR=lib`), giving the layout
`/opt/bear/bin/bear` -> `/opt/bear/libexec/bear/bin/bear-driver` +
`../lib/libexec.so`. The base carries no Rust toolchain (multi-stage build).

## dogfood-fixed-paths

The build runs at fixed, well-known container paths so absolute paths in
`directory` (and in arguments) do not vary between runs, making command lines
reproducible and letting the golden check pass with little or no normalization.

Implementation: zlib builds in-tree at the fixed path `/src` (its `./configure`
has no usable out-of-tree mode). The config pins `SRC_DIR=/src`.

## dogfood-pinned-target

A dogfooding configuration is (base image digest, target source revision,
target build type); all are pinned so the golden stays stable. An unpinned base
would let a package update change the compiler under a fixed golden; an unpinned
build type would change the recorded flags. Release is the default build type.

Implementation: `targets/zlib/config.env` pins the fedora:44 base by digest, the
zlib 1.3.1 tarball by URL + sha256, and `BUILD_TYPE=Release`
(`CFLAGS="-O3 -DNDEBUG"`).

## dogfood-golden-regression

For the pinned target, the suite compares Bear's output against a tracked golden
using `cdb-compare compare` (order-independent multiset equivalence) and flags
any change. The golden is a frozen, full normalized compilation database emitted
with `cdb-compare normalize --sort`, committed under `tests/dogfooding/goldens/`
(NOT under the git-ignored `results/`). The Stage 1 binary is reused as-is; no
hash-manifest tooling is added. The golden is a change-detector, not an
independent proof of correctness.

Implementation: `goldens/zlib/compile_commands.json` is the frozen golden; the
gate is `cdb-compare compare <golden> <fresh>` run on the host. No normalization
flags are used (same pinned image + fixed `/src` => raw multiset matches); if a
benign compiler-path diff ever appears, add `--substitute-compiler cc` to both
the bless and the check, consistently.

## dogfood-golden-rebless

There is a documented, deliberate procedure to regenerate the golden when a
behavior change is intentional, so re-blessing is explicit and reviewable rather
than automatic.

Implementation: `run.sh --rebless <target>` runs the full pipeline, then writes
`cdb-compare normalize --sort <fresh>` to the golden path instead of gating, and
reports "reblessed" for the maintainer to review and commit. See README.md.

## dogfood-preflight

Before launching any container, the suite verifies free disk against a
per-target minimum, that the pinned image digest is present/pullable, and that
the image carries a working Bear (the non-empty-capture check). It exits
non-zero with a clear diagnostic on any failure, so a run never starts only to
leave a torn scratch behind.

Implementation: `run.sh` step 1 checks free disk on the podman graphroot
(`podman info` + `df -Pk`) against `MIN_FREE_KIB` and resolves/pulls the pinned
digest; step 4 runs a trivial `bear -- gcc -c` and asserts the capture is
non-empty before the real build.

## dogfood-build-failure-taxonomy

The harness distinguishes a target build failure (network, source fetch, OOM,
missing target dep, configure/make error) from a Bear/harness failure, and
reports them as distinct outcomes. A target build that fails for its own reasons
is "inconclusive", not a Bear regression.

Implementation: four outcomes with distinct exit codes -
`PASS=0`, `FAIL=1` (golden regression, or oracle matched-TU divergence),
`INCONCLUSIVE=2` (target build failed for its own reasons: target image build,
configure/make), `ERROR=3` (harness or Bear-infra: podman missing, disk/digest
preflight, base build, empty capture, an oracle that matched 0 TUs, missing host
`cdb-compare`). `run.sh` prints one final `OUTCOME:` status line.

## dogfood-oracle-cmake (Stage 3)

For a CMake-native target, the suite compares Bear's output against the database
CMake itself emits (`CMAKE_EXPORT_COMPILE_COMMANDS=ON`), scoped to the
intersection of translation units matched by `file`. The check passes when
matched TUs have equivalent flags under normalization. Entries present in only
one database are logged as "extras", never failures: CMake lists configured TUs
with configure-time flags, while Bear records the actual make-time command, so
a whole-database equality would be pure noise. The oracle renews itself when the
target updates; no hand-maintained baseline. The oracle target is curl (CMake-
native, small); zlib stays the Stage 2 golden target (autotools).

Implementation: `targets/curl/config.env` sets `VALIDATION=oracle` and pins the
fedora:44 base by digest, curl 8.11.1 by URL + sha256, and `BUILD_TYPE=Release`.
The in-container command (dogfood-fixed-paths) configures out-of-tree (source
`/src`, build `/build`) with `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` and the
optional dependencies turned off (no TLS/nghttp2/zlib/zstd/brotli/psl/idn/ssh/
ldap), so curl builds with just cmake+gcc+make. The CMake *configure* step is
NOT wrapped by Bear (it is not a compile); only `cmake --build` is, so Bear's
capture lands at `/out/compile_commands.json` and CMake's reference database is
copied to `/out/oracle.json`. Both are pulled out with `podman cp`.

The comparison is done entirely by the host `cdb-compare` - no jq, no allow-list
file. Three normalizations plus a gating flag make it correct:
`--output-from-o` rewrites each `output` to the absolute object path derived
from the entry's `-o` argument joined with its `directory`, so TUs match by
source file plus the object they produce. That key is identical across producers
even though Bear encodes `output` relative to `directory` and CMake relative to
the build root, and a source compiled into several targets (shared lib, tool)
stays distinct rather than collapsing onto one key. `--drop-dependency-flags`
removes the `-M*` depfile group. `--substitute-compiler cc` absorbs any
compiler-driver path difference. `--intersection` then gates on the `differing`
set alone, reporting `only_in_a`/`only_in_b` as advisory extras. Exit 0 = matched
TUs equivalent (PASS); exit 1 = a real matched-TU divergence (FAIL). The harness
also refuses a vacuous comparison: if 0 TUs matched, the run is an ERROR, not a
silent pass.

## dogfood-divergence-report (Stage 3)

The Bear-only and CMake-only "extras" are reported for review, never a failure.
The one known-benign argument difference on matched TUs - the dependency-file
generation flags (`-MD`/`-MMD`/`-MP` and the argument-consuming
`-MF`/`-MT`/`-MQ`/`-MJ`) - is removed by `cdb-compare --drop-dependency-flags`
before the gate. These flags only control the build system's `.d` side-file,
never the object or how a Clang tool parses the TU, so dropping them is a tested,
documented operation of the comparator rather than a hand-maintained shell
allow-list. On the pinned curl build this group is the ENTIRE matched-but-
differing set (221/221 TUs); with it dropped, `differing` is empty and the gate
passes. `run.sh` writes the comparator's full report (its extras lists plus a
`summary:` line) to `results/<target>/<label>/oracle-report.txt`, with a
machine-readable `oracle-compare.json` alongside. There is no rebless for oracle
targets - the oracle is self-renewing, so `--rebless` is rejected for them.

If a future oracle target exhibits a different benign argument difference that
`--drop-dependency-flags` does not cover, extend the comparator with a tested
rule rather than reintroducing a shell allow-list - the comparison logic stays
in one unit-tested place.
