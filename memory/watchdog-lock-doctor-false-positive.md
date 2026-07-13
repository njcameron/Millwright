---
name: watchdog-lock-doctor-false-positive
description: The watchdog stale-lock/lock-doctor signal is a self-referential false positive, not a real stuck lock
metadata:
  type: project
---

The watchdog signal `stale-lock/lock-doctor` (evidence `state/dispatch_doctor.lock`) is a FALSE POSITIVE caused by a self-referential loop — not a wedged lock. Do NOT delete `dispatch_doctor.lock`: while a doctor runs it is that doctor's own live single-flight lock.

**Why:** `Watchdog#scan` → `lock_signals` globs ALL `dispatch_*.lock` including the watchdog's own `dispatch_doctor.lock` (lib/routines/watchdog.rb:188). And `Watchdog#call` early-returns on healthy ticks (`signals.empty?`, watchdog.rb:86-89) BEFORE `reap_if_finished("doctor")` (watchdog.rb:105), so after a doctor exits its lock is only reaped on a tick that already has a signal. The lock lingers at its last `lock("doctor")` mtime; after 45m (`stale_lock_minutes`) it self-trips → spawns a doctor about its own lock → re-arms the timer → loops roughly every 45m of otherwise-healthy operation.

**How to apply:** When dispatched for `stale-lock/lock-doctor`, confirm `dispatch_doctor.pid` == the running doctor's parent pid and that pid is alive, confirm prior doctor pids are dead, then report diagnose-only — do not delete the lock or kill anything. Proposed code fix (not yet applied as of 2026-06-13): exclude `name == "doctor"` from `lock_signals`' glob, and/or move `reap_if_finished("doctor")` above the `signals.empty?` early-return. See [[debug-pr]] cross-referencing method (orchestrator/watchdog logs under `logs/<date>/`).
