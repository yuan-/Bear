# Process-tree teardown and event-driven supervision

Status: proposed alongside `plan.md`; finalize on approval of the
`interception-signal-forwarding` update.

## Context

When Bear supervises a build (`bear -- make`) and a termination signal
arrives, the whole process subtree underneath the build must stop, within
the sub-one-second budget the signal-forwarding requirement sets, and Bear
should still be able to write the partial `compile_commands.json` it has
collected so far. The original `supervise()` only `child.kill()`ed the
direct child with `SIGKILL`, which (a) left grandchildren reparented to
init and running, and (b) being un-trappable, gave neither a build's own
trap nor in-flight compilers any chance to wind down.

Three mechanisms can terminate an entire subtree, one per platform family:

| Platform | Mechanism | A child can escape it? |
|---|---|---|
| any unix | process group (`setsid`/`setpgid`) + `killpg` | yes - by calling `setsid` itself |
| Linux | cgroup v2 `cgroup.kill` | no - unprivileged moves are denied |
| Windows | Job Object (`KILL_ON_JOB_CLOSE`) | no |

Process groups are portable across unix and need no new dependency (`libc`
is already present); the same group-kill *technique* is already proven in
the version-probe watchdog (`semantic/interpreters/compilers/probe.rs`),
though Stage 1 uses the lighter `Command::process_group(0)` (safe std, keeps
the session) rather than the watchdog's `unsafe` `setsid`. Their one gap is
a child that
deliberately `setsid`s away to daemonize. cgroups close that gap but require
cgroup v2, a writable/delegated cgroup directory, and
`clone3(CLONE_INTO_CGROUP)` or a `pre_exec` write to `cgroup.procs` - none
exposed by `std::process::Command` - plus a runtime fallback. Job Objects
need a `windows-sys` dependency, and Bear has too few Windows users to
justify designing that path yet.

Two further forces shaped the design:

- **Waiting without polling.** `std::process::Child::wait()` blocks
  uninterruptibly and cannot watch for a signal at the same time, which is
  why the original loop polled with `try_wait()` + `sleep(100ms)`. A
  SIGCHLD-driven blocking loop (portable, reuses the already-present
  `signal-hook`) removes the poll and its latency; a Linux-only `poll()`
  over a `pidfd` + `signalfd` would be strictly nicer but Linux-5.3+ and
  more `libc` code.

- **Nested supervisors.** In wrapper mode the chain is `bear-driver` ->
  `make` -> `bear-wrapper` -> real `cc` (the wrapper is a Rust binary on the
  same `supervise()` path, not a shell script). If *every* level created a
  new process group, the build would fragment into many groups and a
  top-level `killpg` would miss the deeper processes - re-opening the very
  escape hole grouping is meant to close.

## Decision

- **Two-stage tree teardown.** *Stage 1* (now): `process_group(0)` +
  `killpg`, behind a `cfg`-selected `platform` submodule (`configure` /
  `terminate` / `wait`) exposing one identical surface per platform.
  *Stage 2* (later):
  cgroup v2 `cgroup.kill` with a Stage 1 fallback, to close the
  `setsid`-escape hole. Both slot in behind the same `platform` functions
  without changing `supervise()`. A Windows Job Object is a possible later
  third path; for now non-unix keeps single-process `child.kill()`.
- **Only the outermost supervisor groups.** The driver creates the group
  and owns the authoritative `killpg`; nested wrappers inherit the group
  and merely forward, so a single top-level `killpg` reaches the whole
  tree. Grouping is therefore a per-caller policy, not baked
  unconditionally into shared `supervise()`.
- **Graceful, real-signal forwarding.** Forward the signal Bear actually
  received (not a hardcoded one) to the group, give the tree a grace window
  to wind down and let Bear write the partial database, then escalate to
  `SIGKILL`.
- **SIGCHLD-driven event loop** replaces the poll; the grace-then-`SIGKILL`
  escalation runs off a deadline inside that loop. pidfd + signalfd is a
  deferred Linux-only optimization behind the same `wait` function.

## Consequences

- No new dependency for Stage 1; `libc` and `signal-hook` are already in the
  tree (the latter needs its `iterator` feature enabled), and the group-kill
  technique is borrowed from the existing watchdog.
- The poll and its up-to-100ms latency are gone; teardown reacts at signal
  speed, inside the budget.
- The child leaves Bear's process group, so the tty no longer delivers
  Ctrl-C to the build directly - Bear becomes the sole conduit. This is what
  makes reliable tree-kill and real-signal forwarding possible and fixes
  trap support in the non-tty (CI `SIGTERM`) case; the trade-off is that any
  gap in Bear's forwarding loses the tty backstop. Accepted.
- After Stage 1, one hole remains: a child that `setsid`s away to daemonize.
  Closing it is exactly what Stage 2 (cgroups) is for, and the trigger to
  schedule it.
- The "only the outermost supervisor groups" rule keeps wrapper-mode nesting
  correct and keeps the wrapper's supervision simple (forward + propagate
  exit code).
- The `platform` seam keeps cgroups, Job Objects, and pidfd as drop-in
  upgrades rather than rewrites.

## References

- Requirement: `interception-signal-forwarding`
- Prior art in-tree: the version-probe watchdog's `setsid` + `killpg`
  teardown (`semantic/interpreters/compilers/probe.rs`)
- Plan: `plan.md` (repo root, transient)
