# Bear dogfooding harness (Stage 2)

A non-automated, release-time harness that runs Bear's *installed release*
binaries against a real project (zlib at a pinned tag) inside a throwaway
container, then gates the captured `compile_commands.json` against a committed
golden. It proves the end-to-end interception loop and catches behavioral
regressions in Bear's output on a real build.

This is the host-orchestrated Podman model (feasibility.md Option C): the
orchestrator is POSIX `sh` on the host, each target runs in a per-project
throwaway container, and nothing touches the repo working tree or the
devcontainer image. The only Rust dependency is the Stage 1 `cdb-compare`
binary, built on the host and used as the comparison gate.

The harness contracts are written up in `SPEC.md` (the `dogfood-*` Stage 2
specs). They live here, not under `docs/requirements/`, because they govern the
test harness, not Bear itself.

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
- Enough free disk on the podman graphroot (zlib needs ~2 GiB for the base +
  target images). The harness preflight checks this.

## How to run

From the repo root:

```sh
# Gate the fresh capture against the committed golden (default target zlib).
tests/dogfooding/run.sh

# Name the run (results land under results/zlib/rc1/).
tests/dogfooding/run.sh --label rc1

# Keep the throwaway container for inspection.
tests/dogfooding/run.sh --keep
```

The first invocation builds two cached images (`bear-dogfood-base:<sha>` and
`bear-dogfood-zlib:<sha>`, tagged by the Bear commit under test); subsequent
runs reuse them. The base build compiles Bear from `git archive HEAD`, so it
takes a few minutes the first time.

## Outcomes and exit codes

The harness prints one final `OUTCOME:` line and exits with:

| Outcome      | Exit | Meaning |
|--------------|------|---------|
| PASS         | 0    | Fresh capture matches the golden; no regression. |
| FAIL         | 1    | Golden mismatch: a real behavioral change in Bear's output. Review the saved diff, then either fix Bear or rebless. |
| INCONCLUSIVE | 2    | The target build failed for its own reasons (source fetch, sha, network, configure/make, OOM). Not a Bear regression. The build log is saved. |
| ERROR        | 3    | Harness or Bear-infra failure: podman missing, disk/digest preflight, base image build, empty capture (libexec/INTERCEPT_LIBDIR mismatch), or missing host `cdb-compare`. |

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

## What the harness does NOT do

- It does not modify the repo working tree, the devcontainer image, or any
  cargo cache. Sources and toolchain live only in the throwaway container.
- It does not leave its per-run container behind (unless `--keep`). It does
  leave the two cached images so reruns are fast; remove them with
  `podman rmi bear-dogfood-zlib:<sha> bear-dogfood-base:<sha>` when done.
