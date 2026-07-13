---
name: doctor-lock-self-inflicted-alarm
description: Recurring false stale-lock/lock-doctor watchdog alarm caused by the doctor single-flight lock never being released on worker exit
metadata:
  type: project
---

The watchdog periodically fires a false `stale-lock/lock-doctor` signal (on `state/dispatch_doctor.lock`) and spawns a doctor to fix its own single-flight lock. This is a self-inflicted, recurring false alarm — a CODE bug, not a real wedge.

**Mechanism:** `Watchdog#dispatch_investigation` (lib/routines/watchdog.rb:248) calls `dispatch_lock.lock("doctor")` but never `record_pid("doctor", pid)`, and nothing ever calls `unlock`/`reap_if_finished("doctor")`. So the doctor lock is only released by the 60m `DispatchLock::TTL_SECONDS`. Meanwhile `lock_signals` (watchdog.rb:181) flags any `dispatch_*.lock` by raw **mtime** age > `stale_lock_minutes` (45m), independent of TTL. Since 45m < 60m, an idle doctor lock self-trips in the 45–60m window. Spawning the doctor re-touches the lock → resets the clock → recurs ~45m later. Cosmetically "self-clears" each cycle (announce_recoveries posts a hollow "recovered"), so it never reaches max_fix_attempts.

**Proposed fix (NOT yet applied — touches code):** (1) in `dispatch_investigation`, after spawn call `record_pid("doctor", pid)` and reap the doctor lock each tick via `reap_if_finished("doctor")` — same pattern plan/ci-fix locks already use. (2) Harden `reap_if_finished`: it returns early unless `locked?`, so a dead-pid lock past its 60m TTL is never unlinked and keeps tripping the mtime-based `lock_signals` forever — let reaping unlink dead-pid locks even after TTL.

**History:** flagged & reported to Slack by the doctor on 2026-06-10 at ~16:20, ~17:21, and again ~18:19 (this run, which also deleted the orphaned lock to break the cycle). The same record_pid/reap gap also stranded `dispatch_ci-533.lock`. See [[doctor-safe-remediation-scope]].
