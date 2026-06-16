// SPDX-License-Identifier: GPL-3.0-or-later

//! Requirements: interception-signal-forwarding

use intercept::Execution;
use std::path::PathBuf;
use std::process::ExitStatus;
use thiserror::Error;

/// Whether this supervisor owns the build's process group or merely inherits it.
///
/// In wrapper mode the supervision chain nests
/// (`bear-driver` -> `make` -> `bear-wrapper` -> real `cc`); only the
/// outermost supervisor may create a process group. If every level created
/// its own group, a top-level group kill would miss the deeper processes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupPolicy {
    /// The outermost supervisor (the driver). Creates a new process group with
    /// the child as leader and owns the authoritative escalation: forward the
    /// received signal to the whole group, grant a grace window, then escalate
    /// to `SIGKILL`.
    Leader,
    /// A nested supervisor (the wrapper). Stays in the inherited group and only
    /// relays the received signal to its direct child; the driver's group kill
    /// is the authoritative teardown, so it runs no grace/`SIGKILL` timer.
    Inherit,
}

/// This method supervises the execution of a command.
///
/// It starts the command and waits for its completion. While waiting it
/// forwards termination signals it receives to the build so the build stops
/// too, and propagates the build's exit status back to the caller.
///
/// On Unix a `Leader` supervisor places the child in a new process group and,
/// on a termination signal, forwards the real signal to the whole group, grants
/// a short grace window, then escalates to `SIGKILL` - so the entire process
/// tree is torn down, not just the immediate child. An `Inherit` supervisor
/// relays the signal to its direct child only and lets the leader's group kill
/// reap the rest.
pub fn supervise(
    command: &mut std::process::Command,
    policy: GroupPolicy,
) -> Result<ExitStatus, SuperviseError> {
    platform::supervise(command, policy)
}

/// This function supervises the execution of a command represented by the `Execution` struct.
pub fn supervise_execution(execution: Execution, policy: GroupPolicy) -> Result<ExitStatus, SuperviseError> {
    let mut child = command_from_execution(execution)?;
    supervise(&mut child, policy)
}

/// Builds a [`std::process::Command`] from an [`Execution`].
///
/// This is a free function rather than a `TryFrom` impl because the orphan
/// rule forbids implementing the foreign `TryFrom`/`Command` for the foreign
/// `Execution` from this crate.
fn command_from_execution(val: Execution) -> Result<std::process::Command, SuperviseError> {
    let mut command = match val.arguments.as_slice() {
        [] => return Err(SuperviseError::EmptyArguments),
        [_] => std::process::Command::new(val.executable),
        [_, arguments @ ..] => {
            let mut cmd = std::process::Command::new(val.executable);
            cmd.args(arguments);
            cmd
        }
    };

    command.envs(val.environment);
    command.current_dir(val.working_dir);
    Ok(command)
}

#[cfg(unix)]
mod platform {
    use super::{GroupPolicy, SuperviseError};
    use signal_hook::consts::signal::SIGCHLD;
    use signal_hook::iterator::Signals;
    use std::path::{Path, PathBuf};
    use std::process::{Child, ExitStatus};
    use std::time::{Duration, Instant};

    /// How long the build's process tree is allowed to wind down on its own
    /// after the real termination signal before the `Leader` escalates to
    /// `SIGKILL`. Kept well under the requirement's sub-one-second budget.
    const GRACE: Duration = Duration::from_millis(400);

    pub(super) fn supervise(
        command: &mut std::process::Command,
        policy: GroupPolicy,
    ) -> Result<ExitStatus, SuperviseError> {
        use std::os::unix::process::CommandExt;

        let executable = PathBuf::from(command.get_program());

        // The leader owns the build's process group so a single killpg reaps
        // the whole tree. process_group(0) is safe std: the child becomes a
        // new group leader (pgid == child pid) before exec.
        if policy == GroupPolicy::Leader {
            command.process_group(0);
        }

        // Watch the termination signals plus SIGCHLD so the wait below blocks
        // until either the build wants to be torn down or the child exits.
        let mut watched: Vec<libc::c_int> = signal_hook::consts::TERM_SIGNALS.to_vec();
        watched.push(SIGCHLD);
        let mut signals = Signals::new(&watched).map_err(|err| SuperviseError::SignalRegistration {
            executable: executable.clone(),
            source: err,
        })?;

        let mut child = command
            .spawn()
            .map_err(|err| SuperviseError::ProcessSpawn { executable: executable.clone(), source: err })?;
        let child_pid = child.id() as libc::pid_t;

        // Close the child-exited-early race: the child may already be gone
        // before we block on the signal iterator.
        if let Some(status) = try_wait(&mut child, &executable)? {
            return Ok(status);
        }

        // Phase 1: wait for either SIGCHLD (child reaped) or a term signal
        // (the teardown trigger). signal-hook's self-pipe persists a signal
        // delivered after registration, so a signal racing this loop is not
        // lost.
        let mut received: Option<libc::c_int> = None;
        for info in &mut signals {
            if info == SIGCHLD {
                if let Some(status) = try_wait(&mut child, &executable)? {
                    return Ok(status);
                }
            } else {
                received = Some(info);
                break;
            }
        }
        // The loop exits only via the `break` above: we never close the signal
        // handle, and `Signals::forever()` ends only on a closed handle. If
        // signal-hook ever closes it out from under us, there is nothing left to
        // forward, so fall back to blocking until the child is reaped.
        let Some(signal) = received else {
            return child.wait().map_err(|err| SuperviseError::ProcessWait { executable, source: err });
        };

        match policy {
            GroupPolicy::Leader => leader_teardown(&mut child, child_pid, signal, &executable),
            GroupPolicy::Inherit => inherit_forward(&mut child, child_pid, signal, &executable, &mut signals),
        }
    }

    /// Leader: deliver the real signal to the whole group, grant a grace
    /// window, then escalate to `SIGKILL`. The leader runs the single
    /// authoritative escalation timer for the supervision chain.
    fn leader_teardown(
        child: &mut Child,
        pgid: libc::pid_t,
        signal: libc::c_int,
        executable: &Path,
    ) -> Result<ExitStatus, SuperviseError> {
        log::debug!("Received signal {signal}, forwarding to process group {pgid}");
        send(SendTarget::Group(pgid), signal);

        let deadline = Instant::now() + GRACE;
        loop {
            if let Some(status) = try_wait(child, executable)? {
                return Ok(status);
            }
            if Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }

        log::debug!("Grace window elapsed, sending SIGKILL to process group {pgid}");
        send(SendTarget::Group(pgid), libc::SIGKILL);

        // Nothing left to forward; block until the direct child is reaped. A
        // blocking wait (not a poll loop) avoids burning CPU and does not hang
        // any worse than the kernel itself: if SIGKILL cannot collect the child
        // (e.g. uninterruptible sleep), no caller could have done better.
        child
            .wait()
            .map_err(|err| SuperviseError::ProcessWait { executable: executable.to_path_buf(), source: err })
    }

    /// Inherit: relay the real signal to the direct child only and wait for it
    /// to be reaped. The leader's group kill is authoritative, so no grace or
    /// `SIGKILL` timer runs here.
    fn inherit_forward(
        child: &mut Child,
        child_pid: libc::pid_t,
        signal: libc::c_int,
        executable: &Path,
        signals: &mut Signals,
    ) -> Result<ExitStatus, SuperviseError> {
        log::debug!("Received signal {signal}, forwarding to child {child_pid}");
        send(SendTarget::Process(child_pid), signal);

        if let Some(status) = try_wait(child, executable)? {
            return Ok(status);
        }
        for info in signals {
            if info == SIGCHLD
                && let Some(status) = try_wait(child, executable)?
            {
                return Ok(status);
            }
        }
        // We never close the signal handle, so the loop above only ends if
        // signal-hook closes it itself; in that case block until the child is
        // reaped (the leader's group kill remains the authoritative teardown).
        child
            .wait()
            .map_err(|err| SuperviseError::ProcessWait { executable: executable.to_path_buf(), source: err })
    }

    fn try_wait(child: &mut Child, executable: &Path) -> Result<Option<ExitStatus>, SuperviseError> {
        match child.try_wait() {
            Ok(Some(status)) => {
                log::debug!("Child process exited: {status:?}");
                Ok(Some(status))
            }
            Ok(None) => Ok(None),
            Err(err) => {
                log::error!("Error waiting for child process: {err}");
                Err(SuperviseError::ProcessWait { executable: executable.to_path_buf(), source: err })
            }
        }
    }

    enum SendTarget {
        Group(libc::pid_t),
        Process(libc::pid_t),
    }

    /// Best-effort delivery of a signal to a process or process group.
    ///
    /// Signal forwarding is best effort: a failure to deliver must not turn
    /// into a hard supervision error (only spawn/wait failures are fatal).
    /// `ESRCH` - the target already exited, the normal exit-then-signal race -
    /// is benign and logged at debug; any other errno is logged at error.
    fn send(target: SendTarget, signal: libc::c_int) {
        // SAFETY: kill()/killpg() are async-signal-safe libc calls taking
        // plain integers; they cannot violate memory safety. We inspect errno
        // only on the documented -1 return.
        let rc = unsafe {
            match target {
                SendTarget::Group(pgid) => libc::killpg(pgid, signal),
                SendTarget::Process(pid) => libc::kill(pid, signal),
            }
        };
        if rc == -1 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::ESRCH) {
                log::debug!("Signal target already gone (ESRCH), nothing to forward");
            } else {
                log::error!("Failed to forward signal {signal}: {err}");
            }
        }
    }
}

#[cfg(not(unix))]
mod platform {
    use super::{GroupPolicy, SuperviseError};
    use std::path::PathBuf;
    use std::process::ExitStatus;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread;
    use std::time::Duration;

    /// A blocking `wait()` cannot be interrupted by a signal on this platform
    /// (no `SIGCHLD`), so the term-signal flag is observed by polling. Process
    /// groups are out of scope here, so `GroupPolicy` is ignored and only the
    /// direct child is signalled.
    pub(super) fn supervise(
        command: &mut std::process::Command,
        _policy: GroupPolicy,
    ) -> Result<ExitStatus, SuperviseError> {
        let executable = PathBuf::from(command.get_program());
        let signaled = Arc::new(AtomicUsize::new(0));
        for signal in signal_hook::consts::TERM_SIGNALS {
            signal_hook::flag::register_usize(*signal, Arc::clone(&signaled), *signal as usize).map_err(
                |err| SuperviseError::SignalRegistration { executable: executable.clone(), source: err },
            )?;
        }

        let mut child = command
            .spawn()
            .map_err(|err| SuperviseError::ProcessSpawn { executable: executable.clone(), source: err })?;

        loop {
            if signaled.swap(0usize, Ordering::SeqCst) != 0 {
                log::debug!("Received signal, forwarding to child process");
                child.kill().map_err(|err| SuperviseError::ProcessKill {
                    executable: executable.clone(),
                    source: err,
                })?;
            }

            match child.try_wait() {
                Ok(Some(exit_status)) => {
                    log::debug!("Child process exited: {exit_status:?}");
                    return Ok(exit_status);
                }
                Ok(None) => {
                    thread::sleep(Duration::from_millis(100));
                }
                Err(err) => {
                    log::error!("Error waiting for child process: {err}");
                    return Err(SuperviseError::ProcessWait { executable: executable.clone(), source: err });
                }
            }
        }
    }
}

/// Errors that can occur during process supervision.
#[derive(Error, Debug)]
pub enum SuperviseError {
    #[error("Failed to register signal handler for '{executable}': {source}", executable = executable.display())]
    SignalRegistration {
        executable: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("Failed to execute '{executable}': {source}", executable = executable.display())]
    ProcessSpawn {
        executable: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("Failed to kill process '{executable}': {source}", executable = executable.display())]
    ProcessKill {
        executable: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("Failed to wait for process '{executable}': {source}", executable = executable.display())]
    ProcessWait {
        executable: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("Execution arguments cannot be empty")]
    EmptyArguments,
}

#[cfg(all(test, unix))]
mod tests {
    // Requirements: interception-signal-forwarding
    //
    // Only the normal-exit path is unit-tested here. The signal-forwarding
    // paths (real-signal forward, grace window, SIGKILL escalation, whole-tree
    // teardown) are verified end to end against the real driver in the
    // integration suite (tests/integration, exit_codes.rs): driving supervise()
    // in-process is unsafe, because signal-hook handlers are process-global and
    // would bleed across parallel unit tests.
    use super::*;
    use std::process::Command;

    #[test]
    fn normal_exit_propagates_status() {
        // arrange / act / assert per case: (exit code, expected success)
        let cases = [(0, true), (7, false)];
        for (code, expect_success) in cases {
            let mut command = Command::new("sh");
            command.arg("-c").arg(format!("exit {code}"));

            let sut = supervise(&mut command, GroupPolicy::Leader).expect("supervise failed");

            assert_eq!(sut.success(), expect_success, "exit {code} success mismatch");
            assert_eq!(sut.code(), Some(code), "exit {code} code mismatch");
        }
    }
}
