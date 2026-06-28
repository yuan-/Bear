# Dogfooding harness specification - Stage 2

These are the Stage 2 `dogfood-*` contracts the harness under
`tests/dogfooding/` satisfies. They are contracts on the TEST HARNESS, not on
Bear, so they intentionally live here and NOT under `docs/requirements/` (which
is reserved for Bear's own contracts). They are condensed from the staged plan;
the plan is the source of intent, this file is the implemented spec.

Scope: non-automated, run by the maintainer at release time. Bear's installed
release binaries are run against a real project (zlib at a pinned tag) inside a
throwaway container, and the captured compilation database is gated against a
committed golden. Sources and toolchain live only in the container, never in
the repo or the devcontainer image (feasibility.md Option C).

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
`PASS=0`, `FAIL=1` (golden regression), `INCONCLUSIVE=2` (target build failed
for its own reasons: target image build, configure/make), `ERROR=3` (harness or
Bear-infra: podman missing, disk/digest preflight, base build, empty capture,
missing host `cdb-compare`). `run.sh` prints one final `OUTCOME:` status line.
