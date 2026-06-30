# Bear dogfooding harness (Stages 2-6)

A non-automated, release-time harness that runs Bear's *installed release*
binaries against a real project at a pinned revision inside a throwaway
container, then validates the captured `compile_commands.json`. It proves the
end-to-end interception loop and catches behavioral regressions and correctness
divergences in Bear's output on a real build.

Each target picks a validation mode with a `VALIDATION` selector in its
`config.env`:

- **golden** (zlib, Stage 2): gate the capture against a committed golden CDB -
  a change-detector, reblessed deliberately when behavior changes intentionally.
- **oracle** (curl, Stage 3): gate the capture against the database CMake itself
  emits (`CMAKE_EXPORT_COMPILE_COMMANDS=ON`), on the intersection of translation
  units. The oracle is self-renewing: when curl updates, CMake produces a fresh
  reference, so there is no hand-maintained baseline.
- **none** (scale targets ffmpeg and the Linux kernel, Stage 4): no golden and
  no oracle (too large to bless / not CMake). These are run ONLY with the
  target-agnostic checks (`--invariants` / `--determinism` / `--replay` /
  `--consumer`); a no-mode run is rejected with a pointer to those. They prove the checks hold
  from midsize (ffmpeg, ~1945 TUs, custom `configure`) to kernel scale (x86_64
  defconfig, ~3000 TUs) - including that Bear stays deterministic and its
  process-tree teardown holds under a high-`-j` kernel build.

This is the host-orchestrated Podman model (feasibility.md Option C): the
orchestrator is POSIX `sh` on the host, each target runs in a per-project
throwaway container, and nothing touches the repo working tree or the
devcontainer image. The only Rust dependency is the Stage 1 `cdb-compare`
binary, built on the host: it does the entire comparison for both modes
(matching, normalization, and the gate), so the harness needs no jq.

The harness contracts are written up in `SPEC.md` (the `dogfood-*` Stage 2 and
Stage 3 specs). They live here, not under `docs/requirements/`, because they
govern the test harness, not Bear itself.

## Prerequisites

- Rootless Podman (developed against podman 5.8.3). The build container runs
  with `--systemd=always` so Bear's cgroup-based process-tree teardown works;
  this mirrors the devcontainer and needs the host's delegated cgroup
  controllers (`/etc/systemd/system/user@.service.d/delegate.conf` with
  `Delegate=cpu cpuset io memory pids`).
- The host `cdb-compare` binary at `target/release/cdb-compare`. Build it with:

  ```sh
  cargo build --release -p bear-test-tools --bin cdb-compare
  ```

  If the host has no C toolchain (cdb-compare's dependencies need a `cc` to
  link their build scripts), build it once in a container and copy it out:

  ```sh
  podman build --build-arg \
    BASE_IMAGE=registry.fedoraproject.org/fedora@sha256:3baf5f0dededfd939eb8f0b271ff8ad17bdb381cdd5768bd7d6f45bba795aa62 \
    -f tests/dogfooding/base/Containerfile -t bear-dogfood-base:tmp .
  cid="$(podman create bear-dogfood-base:tmp)"
  mkdir -p target/release
  podman cp "$cid:/opt/bear/bin/cdb-compare" target/release/cdb-compare
  podman rm "$cid"
  ```

  The base image already builds `cdb-compare`, so this reuses that build.
- Enough free disk on the podman graphroot (zlib needs ~2 GiB, curl ~4 GiB for
  the base + target images plus the CMake build tree). The harness preflight
  checks this against the per-target `MIN_FREE_KIB`.

## How to run

From the repo root:

```sh
# Gate the fresh capture against the committed golden (default target zlib).
tests/dogfooding/run.sh

# Run the curl oracle target (compares against CMake's own database).
tests/dogfooding/run.sh --label rc1 curl

# Name the run (results land under results/zlib/rc1/).
tests/dogfooding/run.sh --label rc1

# Keep the throwaway container for inspection.
tests/dogfooding/run.sh --keep

# Determinism self-check: run the target twice and compare the two captures
# (any target; skips the golden/oracle gate).
tests/dogfooding/run.sh --determinism zlib
tests/dogfooding/run.sh --determinism curl

# Structural invariants on one capture (any target; skips the gate).
tests/dogfooding/run.sh --invariants zlib
tests/dogfooding/run.sh --invariants curl

# Replay a sample of entries in their recorded directories (default 20;
# --replay=N or --replay N to change the count).
tests/dogfooding/run.sh --replay zlib
tests/dogfooding/run.sh --replay=30 curl

# Feed a sample of entries to a clang-tooling consumer (clang-tidy) and assert
# the tool accepts each (default 20; --consumer=N or --consumer N).
tests/dogfooding/run.sh --consumer curl
tests/dogfooding/run.sh --consumer=30 zlib

# Self-test: prove the checks catch injected faults (no container, fast).
tests/dogfooding/selftest.sh
```

The first invocation builds two cached images (`bear-dogfood-base:<sha>` and
`bear-dogfood-<target>:<sha>`, tagged by the Bear commit under test); subsequent
runs reuse them. The base build compiles Bear from `git archive HEAD`, so it
takes a few minutes the first time. The curl build itself takes a few minutes.

## Outcomes and exit codes

The harness prints one final `OUTCOME:` line and exits with:

| Outcome      | Exit | Meaning |
|--------------|------|---------|
| PASS         | 0    | golden: fresh capture matches the golden. oracle: matched TUs equivalent to the CMake oracle. determinism: the two captures are equivalent. invariants: all structural invariants hold. replay: every sampled entry replayed (>=1 verified). consumer: clang-tidy built the AST for every sampled entry (>=1 verified). No regression. |
| FAIL         | 1    | golden: golden mismatch (review the diff, then fix Bear or rebless). oracle: matched TUs diverge from CMake's database (inspect the `matched but differing` section of `oracle-report.txt`). determinism: the two captures differ across two identical builds (see `determinism-diff.txt`). invariants: a structural invariant failed - Bear produced a malformed CDB (see `invariants-report.txt`). replay: a recorded command failed to replay - a malformed entry (see `replay_result`). consumer: clang-tidy rejected a well-formed entry - a semantically broken DB, e.g. a wrong/missing `-I` (see `consumer_result`). A real behavioral change / defect in Bear's output. |
| INCONCLUSIVE | 2    | The target build failed for its own reasons (source fetch, sha, network, configure/make, OOM). For replay, also: every sampled entry was inconclusive (all failures were missing generated inputs, so nothing was actually verified). For consumer, also: every sampled entry was inconclusive (the TU source was no longer on disk), so nothing was actually consumed. Not a Bear regression. |
| ERROR        | 3    | Harness or Bear-infra failure: podman missing, disk/digest preflight, base image build, empty capture (libexec/INTERCEPT_LIBDIR mismatch), an oracle that matched 0 TUs (nothing compared), missing host or in-image `cdb-compare`, or a non-numeric/zero object count. |

Run artifacts land under `results/<target>/<label>/` (git-ignored). Goldens
live under `goldens/<target>/` and are tracked.

## Reblessing the golden (dogfood-golden-rebless)

The golden is a frozen, full normalized CDB - a change-detector, not a proof of
correctness. When a behavior change is intentional (Bear deliberately changed
the flags it records, or the pinned zlib/base moved), regenerate it
deliberately:

```sh
tests/dogfooding/run.sh --rebless zlib
```

This runs the full pipeline (preflight, base + target build, smoke,
real build) and then, instead of gating, writes
`cdb-compare normalize --sort <fresh>` to
`goldens/zlib/compile_commands.json` and reports "reblessed" (exit 0). The new
golden is left in the working tree for you to:

1. Inspect the diff (`git diff tests/dogfooding/goldens/zlib/`) and confirm the
   change is the one you intended.
2. Commit it with a message explaining *why* the recorded behavior changed.

Reblessing is never automatic: a normal `run.sh` only ever reads the golden and
fails on mismatch, so an unintended change cannot silently overwrite it.

## The curl oracle target (dogfood-oracle-cmake)

curl is CMake-native, so CMake itself can emit the reference compile database.
The harness configures curl out-of-tree (source `/src`, build `/build`) with
`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` and all optional dependencies turned off,
then wraps only the *build* with Bear (the configure step is not a compile).
This captures both databases from one run:

- `/out/compile_commands.json` - Bear's capture of the real make-time compiles.
- `/out/oracle.json` - CMake's own database (the independent oracle).

### Extras vs the gate

The comparison is scoped to the *intersection* of translation units, matched by
source file plus the object it produces. The two databases legitimately differ
in coverage, so the result splits in two:

- **Extras** (`only_in_a` Bear-only, `only_in_b` CMake-only): TUs present in
  only one database. CMake lists every configured TU (including ones a given
  build target does not actually compile), while Bear records what the build
  really ran. Extras are *logged for review, never a failure*. On the pinned
  build there are 0 Bear-only and ~156 CMake-only extras.
- **The gate** (`differing`): TUs matched on both sides whose flags differ after
  normalization. The gate passes iff this set is empty.

The comparison is one `cdb-compare` invocation (no jq, no allow-list file):

```sh
cdb-compare compare --intersection --substitute-compiler cc \
    --output-from-o --drop-dependency-flags  <bear.json> <cmake.json>
```

- `--output-from-o` matches TUs by source file plus absolute object path
  (`directory` + the `-o` argument), so the two producers' differently encoded
  `output` fields align and a source compiled into several targets stays
  distinct.
- `--drop-dependency-flags` removes the `-M*` dependency-file group (`-MD`,
  `-MMD`, `-MP`, and the arg-consuming `-MF`/`-MT`/`-MQ`/`-MJ`). On curl this is
  the entire matched-but-differing set: the real compile carries them, CMake's
  configure-time export omits them, and they touch only the `.d` side-file,
  never the object. This is a tested operation of the comparator, not a shell
  heuristic.
- `--intersection` makes the exit code gate on `differing` only; extras are
  advisory. The harness additionally fails the run if 0 TUs matched (a vacuous
  comparison that validated nothing).

The comparator's report (extras lists plus a `summary:` line) is written to
`results/curl/<label>/oracle-report.txt`, with a machine-readable
`oracle-compare.json` alongside. When the gate fails, inspect the
`matched but differing` section. If a future oracle target shows a *different*
benign argument difference, extend `cdb-compare` (a tested normalization rule),
not a shell allow-list - the comparison stays in one place.

## The determinism check (dogfood-determinism)

`run.sh --determinism <target>` runs the SAME target's build twice in two fresh
throwaway containers off the same pinned image, captures Bear's compilation
database from each, and compares the two captures. The build is its own
reference - no golden, no oracle - so this works for ANY target (verified on both
zlib and curl). It reuses the same preflight, image builds, non-empty-capture
smoke, and `build_and_capture` helper as a normal run, then SKIPS the
golden/oracle gate.

```sh
tests/dogfooding/run.sh --determinism zlib   # autotools target
tests/dogfooding/run.sh --determinism curl   # runs two CMake builds; slower
```

The comparison uses `cdb-compare compare <run1> <run2>` with NO normalization
flags: the fixed build paths (`/src`, `/build`) make the two captures
multiset-equivalent at the source, and `cdb-compare` is order-independent, so
build parallelism does not matter. PASS means the two captures are equivalent;
FAIL means they genuinely differ across two identical builds - that is real
non-determinism or a race in Bear itself, and the diff is saved to
`results/<target>/<label>/determinism-diff.txt` (with a machine-readable
`.json`). Both captures are kept as `compile_commands.run1.json` and
`compile_commands.run2.json`. A build that fails for its own reasons is
INCONCLUSIVE; infra/empty-capture/missing host `cdb-compare` is ERROR - the same
taxonomy as a normal run. `--determinism` with `--rebless` is rejected (no golden
is involved).

### Self-test: catching an injected fault

The determinism check must demonstrably catch a fault. `--inject-fault` does
that without editing captured JSON by hand: it perturbs the SECOND build with an
extra compiler flag (`-DBEAR_DOGFOOD_INJECTED_FAULT=1`) so the two builds
legitimately diverge.

```sh
tests/dogfooding/run.sh --determinism zlib                 # => PASS (exit 0)
tests/dogfooding/run.sh --determinism --inject-fault zlib  # => FAIL (exit 1)
```

`run.sh` passes a non-empty `INJECT_CFLAGS` into the second container only;
each target's `config.env` threads `${INJECT_CFLAGS:-}` into that build's
compiler flags (`CFLAGS` for zlib's configure, `CMAKE_C_FLAGS` for curl's
cmake). On a normal run and on determinism run 1 the value is empty - a no-op,
so a normal run is unchanged. The FAIL run's `determinism-diff.txt` shows the
injected flag present in run 2's arguments and absent in run 1's, confirming the
check caught the divergence. `--inject-fault` is only valid with `--determinism`.

The DROPPED / DUPLICATED / CORRUPTED-ENTRY faults from the Stage 4 plan are NOT
determinism's territory: they are caught by the invariants and replay checks
below, demonstrated by `selftest.sh`.

## The invariants check (dogfood-invariants)

`run.sh --invariants <target>` builds+captures once, then asserts structural
invariants on the single capture with the host `cdb-compare invariants` and
gates on its exit code (no golden, no oracle, no maintained baseline):

- **non-empty-arguments** - no entry has empty `arguments`.
- **no-true-duplicates** - no two entries share `file` + `output` + normalized
  `arguments`. A source compiled into different outputs with different flags
  (multi-config) is legitimate and is NOT flagged.
- **entry-count** - the entry count is within `OBJECT_TOLERANCE_PCT` of the
  number of object files the build produced.

```sh
tests/dogfooding/run.sh --invariants zlib   # PASS: 34 entries, 34 objects
tests/dogfooding/run.sh --invariants curl   # PASS: 221 entries, 221 objects
```

The object count is taken IN the container before teardown by a per-target
`OBJECT_COUNT_CMD` (config.env), written to `/out/object_count` and pulled out.
It is per-target because "objects produced" is not always "*.o files on disk":
curl's CMake leaves every object under `/build`, so the default
`find $OBJECTS_DIR -name '*.o' | wc -l` is exact, but zlib's in-tree `make`
deletes its PIC objects under `objs/` at link time (19 survive, 34 produced), so
zlib instead counts make's own dependency graph (`make -Bn`). The human report
is saved to `results/<target>/<label>/invariants-report.txt`. PASS = invariants
hold; FAIL = a malformed CDB; a build failure is INCONCLUSIVE and infra is ERROR.

## The replay check (dogfood-replay)

`run.sh --replay[=N] <target>` (default N=20; also `--replay N`) builds+captures
once, then replays a sample of Bear's entries to verify the compiler accepts the
recorded arguments. Replay runs INSIDE the build container as part of the same
`podman run`, because the recorded sources and generated headers exist there
only before teardown.

```sh
tests/dogfooding/run.sh --replay zlib       # PASS: ok=20 fail=0 inconclusive=0
tests/dogfooding/run.sh --replay=30 curl    # PASS: build-dir-aware sample
```

The in-image `cdb-compare sample <capture> --count N --build-dir <BUILD_DIR>`
selects up to N replayable entries (preferring TUs whose flags do not reference
build-dir includes) and emits one shell-quoted replay line per entry. Each is
replayed as `( cd "$dir" && "$@" -fsyntax-only )` and tallied:

- **OK** - the compiler accepted the recorded arguments.
- **INCONCLUSIVE** - the failure is a missing input (a generated header gone
  after teardown: stderr matches "No such file" / "file not found" / "not
  found"). Not a Bear fault.
- **FAIL** - any other failure, including a recorded `directory` that does not
  exist (a corrupted-directory fault). A malformed entry.

Gate (non-vacuity, mirroring the oracle): any real FAIL => FAIL; all OK
(inconclusive allowed) => PASS; EVERY sampled entry inconclusive (nothing
verified) => INCONCLUSIVE. The tally and any failing commands are saved to
`results/<target>/<label>/replay_result`. On the pinned builds all 20 sampled
entries replay OK for both targets.

## The clang-consumer check (dogfood-clang-consumer)

`run.sh --consumer[=N] <target>` (default N=20; also `--consumer N`)
builds+captures once, then feeds a sample of Bear's entries to a real
clang-tooling consumer and asserts the tool can build the AST from each. This is
the one check that validates the database WORKS in the tool it exists for -
catching a structurally-valid but semantically-broken DB (a wrong/missing `-I`,
a dropped `-x`, a missing sysroot) that the invariants and replay checks miss.
Like replay, it runs INSIDE the build container as part of the same `podman run`,
because the consumer needs the recorded sources and generated headers (present
only before teardown) AND because the clang tooling lives in the image (the host
has no clang).

```sh
tests/dogfooding/run.sh --consumer curl      # PASS: ok=20 fail=0 inconclusive=0
tests/dogfooding/run.sh --consumer=30 zlib   # build-dir-aware sample of 30
```

The targets build with GCC, so clang tooling must consume a gcc-built
`compile_commands.json`. The consumer (chosen empirically) is:

```sh
clang-tidy --checks='-*,bugprone-assert-side-effect' --allow-no-checks \
    -p <cdb-dir> <file>
```

clang-tidy reads the gcc-recorded command from the CDB at `-p <cdb-dir>` and
mangles the driver-incompatible flags itself (it drops GCC-only flags clang does
not know) - that cross-compiler consumption is exactly what the check validates.
A single real check forces a full front-end parse (with no check enabled
clang-tidy short-circuits and never parses); `--allow-no-checks` keeps the run
from erroring should that check name ever disappear. `clangd --check` was
rejected as the consumer: it runs clangd's internal tweak self-tests and reports
their failures as "N errors" with a non-zero exit even when the AST built
perfectly, so its exit code is not a database-validity signal.

The in-image `cdb-compare sample <capture> --count N --build-dir <BUILD_DIR>`
selects up to N replayable entries (build-dir-aware, the same sampler replay
uses) and emits one shell-quoted line per entry. The loop identifies the source
file in each argv and runs the consumer over it, tallied:

- **OK** - zero `error:` diagnostics: clang-tidy parsed the TU and built the AST.
  Warnings are expected on a gcc TU under clang and are not a defect.
- **FAIL** - one or more `error:` diagnostics, INCLUDING a not-found `#include`.
  The consumer runs in the LIVE post-build container, so every header the build
  saw is still on disk; a "file not found" is therefore a wrong/missing-`-I`
  defect, not a generated-header artifact. This is the signal the check exists
  for.
- **INCONCLUSIVE** - the TU source itself is no longer on disk (the one genuine
  missing-input case). Kept narrow so the not-found-header FAIL is not diluted.

Gate (non-vacuity, mirroring the oracle): any FAIL => FAIL; all OK (inconclusive
allowed) => PASS; EVERY sampled entry inconclusive (nothing consumed) =>
INCONCLUSIVE. The tally and any rejected entries are saved to
`results/<target>/<label>/consumer_result`. On the pinned curl build all 20
sampled entries come back OK - clang-tidy consumes the gcc-recorded database
cleanly and parses every TU without error, so the check gives meaningful signal
on a gcc-built target, not noise.

### Fault demo: catching a stripped `-I` (the Stage 6 exit criterion)

The check must demonstrably catch a deliberately broken entry. Because the host
has no clang, the demo runs IN the container (unlike the replay bad-directory
fault, a host-side `selftest.sh` fixture). `consumer-fault-demo.sh` is a small,
labeled in-container one-off run against the curl target image:

```sh
podman run --rm --systemd=always \
    -v tests/dogfooding/consumer-loop.sh:/consumer-loop.sh:ro,Z \
    -v tests/dogfooding/consumer-fault-demo.sh:/demo.sh:ro,Z \
    bear-dogfood-curl:<sha> sh /demo.sh
```

It builds curl, takes a known-good entry (`altsvc.c`, which the consumer accepts
as OK), strips the `-I/src*` flags it needs to find `curl/system.h`, and shows
the SAME shipped `consumer_cdb` function then reports FAIL for that entry:

```
good: rc=0 (ok=1 fail=0 inconclusive=0)
bad:  rc=1 (ok=0 fail=1 inconclusive=0)
  diag: /src/lib/curl_setup.h:330:10: error: 'curl/system.h' file not found
DEMO PASSED
```

The demo exits 0 iff the good entry was OK and the broken entry was caught. No
JSON is hand-edited beyond removing the one include group; the fault is a real,
broken database entry.

## The self-test: catching injected faults (the Stage 4 exit criterion)

`tests/dogfooding/selftest.sh` demonstrates that the checks catch the plan's
injected faults - a dropped entry, a duplicated entry, and a corrupted
`directory` - WITHOUT a container and without `jq`, so it is fast. It runs the
host `cdb-compare` (and the same `replay-loop.sh` function the in-container
replay uses) against tiny, committed fault fixtures under `faults/` and asserts
each check exits non-zero:

```sh
tests/dogfooding/selftest.sh   # all faults caught => exit 0
```

| Fixture                      | Fault                | Caught by |
|------------------------------|----------------------|-----------|
| `faults/duplicate.json`      | duplicated entry     | invariants (no-true-duplicates) |
| `faults/empty-arguments.json`| empty `arguments`    | invariants (non-empty-arguments) |
| `faults/undercount.json`     | dropped entry        | invariants (entry-count, `--expected-objects 3`) |
| `faults/bad-directory.json`  | corrupted `directory`| replay (recorded directory does not exist) |

A control case (an honest CDB passes invariants) guards against false positives.
The fixtures are hand-written and committed (outside the git-ignored `results/`)
so the fault is unambiguous, not the product of fragile in-shell JSON surgery.

## Metrics: profiling bear-driver with rprof (dogfood-metrics-collect)

`--metrics` additionally profiles `bear-driver`'s CPU/memory with rprof while it
builds the target, and keeps the FULL rprof JSONL at
`results/<target>/<label>/metrics.jsonl` (determinism: `metrics.run1.jsonl` /
`metrics.run2.jsonl`). It profiles `bear-driver` specifically - the `bear` entry
script execs the driver and rprof measures only that process, not the compiler
descendants.

```sh
tests/dogfooding/run.sh --metrics ffmpeg              # profiled build, metrics only
tests/dogfooding/run.sh --metrics --invariants curl   # invariants + a profile
tests/dogfooding/run.sh --metrics --determinism zlib  # two builds, two profiles
```

The harness only COLLECTS the file; it never parses or summarizes it. Render and
compare runs yourself with `rprof view`. rprof (v1.0.0) is baked into the base
image and is harmless when `--metrics` is not given.

## What the harness does NOT do

- It does not modify the repo working tree, the devcontainer image, or any
  cargo cache. Sources and toolchain live only in the throwaway container.
- It does not leave its per-run container behind (unless `--keep`). It does
  leave the two cached images so reruns are fast; remove them with
  `podman rmi bear-dogfood-<target>:<sha> bear-dogfood-base:<sha>` when done.
