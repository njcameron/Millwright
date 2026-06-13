# Changelog

## v0.6.0 — 2026-06-13

- Let the Claude Code coding-agent pin its model via `coding_agent.model` (passed as `--model`). The CLI's default model can be one this account lacks access to (e.g. `claude-fable-5`), which silently kills every spawned worker — and the watchdog's own doctor — on startup with a "model unavailable" error. Leaving it unset preserves the old default-model behavior.
- Fix a self-referential watchdog loop: `lock_signals` globbed `dispatch_*.lock` including the watchdog's OWN `dispatch_doctor.lock`, so once that lock aged past `stale_lock_minutes` (45) the watchdog flagged it as stale and spawned a doctor to investigate its own leftover lock — re-touching the lock and repeating roughly every 45m forever. The doctor lock is now excluded; it is self-managed via `DispatchLock` and has its own blocking TTL.
- Reap the watchdog's `doctor` single-flight lock on worker exit (`record_pid` on dispatch + `reap_if_finished` before the single-flight check), matching the v0.5.0 plan/CI handlers. Previously a doctor that died on startup held the lock for the full 1-hour TTL, wedging every retry.

## v0.5.0 — 2026-06-10

- Release dispatch locks as soon as their detached worker exits, instead of waiting out the 1-hour TTL. `PlanCommentHandler` and `CiFailureHandler` left a `plan-<n>`/`ci-<pr>` lock held for the full TTL after the worker finished — blocking the next round of reviewer feedback / the next CI-fix retry for up to an hour (this is what stalled a second round of plan feedback on a live issue). Lock ownership + reaping is centralised in `DispatchLock` (`record_pid` / `reap_if_finished`), which releases a lock once its recorded owner process is gone.
- Add a watchdog `detection-without-dispatch` signal: a handler that logs detected work for the same target across `routines.watchdog.stuck_detection_ticks` ticks (default 5) with no matching `Spawned claude` line is flagged — the symptom-level catch for a wedged dispatch regardless of cause. Also decouple the stale-lock threshold (`routines.watchdog.stale_lock_minutes`, default 45) from the `DispatchLock` TTL so it can fire while a lock is still blocking.

## v0.4.0 — 2026-06-10

- Add a runtime watchdog ("doctor", `bin/watch` → `lib/routines/watchdog.rb`) that runs every minute from its own cron entry, independent of the orchestrator. A deterministic scan detects stalled/hung workers (0-byte log + dead/silent process), the orchestrator not ticking, new `ERROR`/stack-trace lines (byte-cursored), stale dispatch locks, and cards wedged in "In progress" with no live worker. When something is flagged it posts to Slack and — single-flighted and rate-limited, with a per-target attempt cap — spawns one Claude worker that performs safe auto-remediation (reversible actions only) and diagnoses-and-proposes for anything touching code/config (`routines.watchdog.auto_remediate: false` makes it diagnose-only). Distinct from the setup-time `bin/doctor` preflight.
- Add `doctor_detected` / `doctor_gave_up` / `doctor_recovered` update-channel notifications, and make `Orchestrator::Context#worker_runner` injectable for testing.

## v0.3.0 — 2026-06-10

- Add a planning feedback loop: a new `PlanCommentHandler` polls the cc-planning column each tick for unaddressed reviewer comments and dispatches a planning-only worker to revise the plan in place (posts the revised plan as a new comment, leaves the card in cc-planning and the "needs review" label untouched). Mirrors `PrCommentHandler` — posts a WIP reply for dedup and locks `plan-<n>` to prevent concurrent revisions. Previously, comments on a plan in cc-planning were never picked up; feedback was only consumed once the card was manually moved to "Planning approved".
- Add `issue_comments` / `post_issue_comment` to the version-control adapter (the GitHub adapter aliases `pr_issue_comments` to `issue_comments`, since PRs are issues in GitHub's API) and a `plan_comments_found` update-channel notification.

## v0.2.0 — 2026-06-09

- Surface operational errors (missing repo checkout, failed `gh` API calls) to Slack via a new throttled `Context#error` path, so failures are visible instead of only logged. Throttling reuses the existing `Cooldown` so a recurring error notifies at most once per backoff window.
- Fix silently-swallowed `gh` comment failures: `post_pr_comment`/`post_review_reply` now capture stderr and raise on non-zero exit (previously `capture2` dropped stderr and ignored exit status, so a 403 looked like success and leaked to the log).

## v0.1.0 — 2026-06-07

- Initial commit.
