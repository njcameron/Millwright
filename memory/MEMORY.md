# Memory Index

- [Doctor lock self-inflicted alarm](doctor-lock-self-inflicted-alarm.md) — recurring false stale-lock/lock-doctor; doctor single-flight lock never released on worker exit (code bug, unapplied fix)
- [Watchdog lock-doctor false positive](watchdog-lock-doctor-false-positive.md) — stale-lock/lock-doctor is self-referential; never delete dispatch_doctor.lock, report diagnose-only
