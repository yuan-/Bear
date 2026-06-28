# Dogfooding harness specification - Stages 2, 3, and 4

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
chooses the per-target validation mode: `golden` (Stage 2, zlib) gates against a
committed golden; `oracle` (Stage 3, curl) gates against the database CMake
itself emits. Three target-agnostic Stage 4 checks are selected by flag and need no
maintained baseline: `--determinism` (run the same target twice and compare the
two captures), `--invariants` (assert structural invariants on one capture), and
`--replay[=N]` (replay a sample of entries in their recorded directories). Each
builds+captures once (twice for determinism) and skips the golden/oracle gate.

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

## dogfood-determinism (Stage 4)

The suite can run the same target twice and assert Bear's two outputs are
equivalent under `dogfood-cdb-compare`. Any difference indicates non-determinism
or a race in Bear itself; the build is its own reference, no golden and no oracle
required. This is target-agnostic: it runs for any target, golden or oracle.

Implementation: `run.sh --determinism <target>` runs the shared preflight, base
+ target image builds, and the non-empty-capture smoke (exactly as a normal
run), then runs the target build TWICE in two distinct fresh throwaway
containers off the same pinned image (`build_and_capture` in `lib.sh`, invoked
once per container - the same body the normal single-run path uses, so the
build-failure taxonomy is identical), and compares the two captures with
`cdb-compare compare <run1> <run2>`. NO normalization flags are used: the fixed
build paths (`/src`, `/build`) make the two captures multiset-equivalent at the
source, and `cdb-compare` is order-independent, so build parallelism does not
matter. The golden/oracle gate is SKIPPED entirely (determinism is its own
check). `--determinism` with `--rebless` is rejected (ERROR: no golden is
involved); `--inject-fault` outside `--determinism` is likewise an ERROR.

Outcome (reusing the existing taxonomy): both captures equivalent => PASS;
captures differ => FAIL (real Bear non-determinism / a race), with the
`cdb-compare compare` diff saved to `results/<target>/<label>/determinism-diff.txt`
(and `.json`); either build failing for its own reasons => INCONCLUSIVE;
podman/infra/empty-capture/missing host `cdb-compare` => ERROR. Both captures
are written as `compile_commands.run1.json` and `compile_commands.run2.json`.

Self-test (the Stage 4 exit criterion - the check must demonstrably catch a
fault): `run.sh --determinism --inject-fault <target>` perturbs the SECOND build
with an extra compiler flag so the two builds legitimately diverge, and the
check is shown to FAIL. The fault is injected as a real, different second build,
NOT by editing captured JSON by hand: `run.sh` passes a non-empty `INJECT_CFLAGS`
(an extra `-D...` macro) into the second container only, and each target's
`config.env` threads `${INJECT_CFLAGS:-}` into that build's compiler flags
(`CFLAGS` for zlib's configure, `CMAKE_C_FLAGS` for curl's cmake). On a normal
run and on determinism run 1 the value is empty, a no-op. `run.sh --determinism
<target>` (no fault) PASSes; the `--inject-fault` variant FAILs. Both directions
are verified for zlib and curl.

Scope boundary: the DROPPED, DUPLICATED, and CORRUPTED-ENTRY faults from the
Stage 4 plan are NOT determinism's territory - they belong to
`dogfood-invariants` (dropped/duplicated/empty-arguments) and `dogfood-replay`
(corrupted `directory`), both specified below. Determinism's own fault model is
a divergent second build, which is exactly what `--inject-fault` exercises.

## dogfood-invariants (Stage 4)

For any target, the suite asserts structural invariants on Bear's single
capture: every entry has non-empty `arguments`, there are no TRUE duplicates
(identical `file` + `output` + normalized `arguments` - a source compiled into
different outputs with different flags is legitimate, not a duplicate), and the
entry count is within a configured tolerance of the number of object files the
build produced. Each invariant is independently reported. No golden, no oracle,
no maintained baseline.

Implementation: `run.sh --invariants <target>` runs the shared preflight, image
builds, and smoke, builds+captures once (`build_and_capture`), then gates on the
exit code of one host `cdb-compare invariants --drop-dependency-flags
--expected-objects <N> --tolerance <PCT> --format human <capture>`. The whole
structural check - non-empty-arguments, no-true-duplicates, and the entry-count
band - lives in the unit-tested comparator; the harness only supplies `<N>` and
`<PCT>` and gates the exit code (no JSON parsed in shell). Exit 0 => PASS;
exit 1 => FAIL (Bear produced a malformed CDB); a non-1 error or a build/infra
failure maps to ERROR/INCONCLUSIVE via `build_and_capture`. The human report is
saved to `results/<target>/<label>/invariants-report.txt`.

The object count `<N>` is taken IN the container before teardown, by a
per-target `OBJECT_COUNT_CMD` (config.env) written to `/out/object_count` and
pulled out. The instrument is per-target because "objects produced" is not
always "*.o files still on disk": curl's CMake leaves every object under
`/build`, so the default `find $OBJECTS_DIR -name '*.o' | wc -l` is exact, but
zlib's in-tree `make` compiles each library source twice (static + PIC) and
DELETES the PIC objects under `objs/` at link time, so a post-build `find`
undercounts ~1.8x (19 survive, 34 produced). zlib therefore overrides
`OBJECT_COUNT_CMD` to count make's OWN dependency graph
(`make -Bn | grep -oE -e '-o ...\.o' | sort -u | wc -l`) - a build-system-native,
cleanup-independent, Bear-independent count of produced objects. `<PCT>` is the
per-target `OBJECT_TOLERANCE_PCT` (10 for both): with the count instruments
above, entries == objects exactly (zlib 34/34, curl 221/221), so 10% is mere
headroom for an incidental build-system object and keeps the check sensitive to
a real entry drop or duplication.

## dogfood-replay (Stage 4)

The suite takes a sample of Bear's entries and replays each recorded command in
its recorded `directory` with `-fsyntax-only` appended, asserting the compiler
accepts the recorded arguments. A command that fails to replay indicates a
malformed entry (wrong cwd, missing or mangled flag). Sampling size is
configurable. In a throwaway container a generated header may no longer exist,
so a replay failure for a TU that depends on a missing input is *inconclusive*,
not a Bear failure; the sampler preferentially selects TUs whose flags do not
reference build-dir includes to keep replay meaningful.

Implementation: `run.sh --replay[=N] <target>` (default N=20; also `--replay N`)
runs the shared pipeline, builds+captures once, and replays INSIDE the build
container as part of the same `podman run` - the recorded sources and generated
headers exist there only before teardown. The replay loop is one POSIX function
(`replay-loop.sh`) read into the in-container script; the in-image
`/opt/bear/bin/cdb-compare sample <capture> --count N --build-dir <BUILD_DIR>`
selects up to N replayable entries (build-dir-aware) and emits one shell-quoted
replay line per entry (`directory` then argv). Each is replayed as
`( cd "$dir" && "$@" -fsyntax-only )` and tallied: OK (compiler accepted the
args), INCONCLUSIVE (the failure stderr matches a missing-file diagnostic - "No
such file" / "file not found" / "not found" - a build-time input gone after
teardown), or FAIL (any other failure, including a `directory` that does not
exist - a corrupted-directory fault, caught before the compile by a `-d` test).
The function writes its tally and any failing commands to `/out/replay_result`
and its return code to `/out/replay_rc`, both pulled out and gated on without
parsing JSON. `BUILD_DIR` comes from config.env (curl `/build`; zlib has no
out-of-tree dir, so its `BUILD_DIR` is `/src`).

Gate (non-vacuity, mirroring the oracle): any real FAIL => FAIL (a malformed
entry); all OK with inconclusive allowed => PASS; EVERY sampled entry
inconclusive (nothing actually verified) => INCONCLUSIVE (replay must not pass
vacuously). On the pinned builds all 20 sampled entries replay OK for both zlib
and curl (0 FAIL, 0 INCONCLUSIVE).

## dogfood-injected-fault demonstration (Stage 4 exit criterion)

The Stage 4 exit criterion requires the checks to demonstrably catch an injected
fault - a dropped entry, a duplicated entry, and a corrupted `directory`. This
is demonstrated WITHOUT a container by `selftest.sh` against tiny, committed,
hand-written fault fixtures under `faults/` (so the fault is unambiguous and not
the product of fragile in-shell JSON surgery on a real capture):

- `faults/duplicate.json` - two byte-identical entries => `cdb-compare
  invariants` FAILS its no-true-duplicates check.
- `faults/empty-arguments.json` - an entry with `"arguments": []` => invariants
  FAILS non-empty-arguments.
- `faults/undercount.json` - 2 entries asserted against `--expected-objects 3
  --tolerance 0` => invariants FAILS entry-count (the "dropped entry" fault).
- `faults/bad-directory.json` - a valid entry whose `directory` does not exist
  => the replay loop FAILS (the recorded compile can never run from where Bear
  claims it did - the "corrupted directory" fault). `faults/tu/hello.c` is the
  trivial TU it nominally compiles.

`selftest.sh` runs the host `cdb-compare invariants` against the invariants
fixtures and the SAME `replay-loop.sh` function (host-side) against the
bad-directory fixture, asserts each check exits non-zero (the fault was caught),
adds a control that an honest CDB passes (no false positive), and prints a clear
pass/fail. It needs no container and no `jq`, so it is fast and is the
demonstrable-fault-catching deliverable. It is invoked as
`tests/dogfooding/selftest.sh`.
