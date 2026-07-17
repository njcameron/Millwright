# Changelog

## v0.11.0 — 2026-07-17

- Stop spawned workers inheriting `ANTHROPIC_API_KEY`, which outranks the claude.ai subscription login in the Claude CLI's credential precedence. When the key was present in the orchestrator env it leaked into every worker, so each dispatch billed pay-as-you-go API credit instead of the subscription — and once that credit balance drained, every worker (and the doctor) died on startup with `Credit balance is too low`. Because the death is silent (a 76-byte worker log), the cards stayed stranded in *In progress*, held all `max_workers` slots via `count_active_workers`, and deadlocked new dispatch (observed on `njcameron/rh-app` issues 615/620/621). `CodingAgent#env_overrides` now clears `ANTHROPIC_API_KEY` alongside the `CLAUDE_CODE_*` vars, so workers fall through to the subscription OAuth login. Regression test asserts the key is explicitly unset (present with a `nil` value, not merely absent). Graceful detection/comms/back-off for spend-limit stalls is tracked separately in #15. (#15)

## v0.10.0 — 2026-07-13

- Let a human pick the worker model per issue via a `model:<alias>` label on the card. The dispatcher (`resolve_model`) reads the label through the issue tracker (`IssueTracker#model_label`), maps the friendly alias to a real model id via `coding_agent.model_labels` in config, and passes it to the Claude Code adapter as a one-off `--model` override that wins over the configured `coding_agent.model` default. An unknown alias is surfaced (log + throttled Slack) and falls back to the default model rather than silently spawning the wrong model or hard-failing the dispatch. `IssueTracker#model_label` defaults to `nil` (no override) so trackers with no concept of model labels keep working unchanged. Only the issue-dispatch path adopts per-issue selection for now; the plan/PR/CI/watchdog worker paths stay on the configured default. (#11)

## v0.9.0 — 2026-06-17

- Add a `bin/doctor` preflight check (`app_repo_access`) that catches the misconfiguration behind the v0.8.0 re-dispatch loop *before* it bites. The GitHub App installation token issues successfully even when the App was added to the account but never granted access to a particular repo — writes to that repo then 403 (`Resource not accessible by integration`) and workers silently fall back to posting as the **owner** account. Doctor now enumerates every repo that has a card on the board (`IssueTracker#board_repos`) and cross-checks it against the repos the installation can actually reach (`GET /installation/repositories`, called with the App token). Any board repo the App can't reach is a hard **fail** naming the repo, with a hint to grant access under the App's *Repository access* settings — so a degraded install turns red at preflight instead of looping at runtime. The v0.8.0 factory-reply marker remains the runtime safety net for the legitimate fallback. (#7)

## v0.8.0 — 2026-06-17

- Stop the PR/plan comment re-dispatch loop. `PrCommentHandler` and `PlanCommentHandler` only treated a comment as *addressed* when a reply's author equalled `factory_username` (the bot). But on repos where the GitHub App token is read-only, workers strip `GH_TOKEN` and post their replies as the **owner** account — so genuine worker replies never satisfied the dedup, and the orchestrator re-detected the same comment every tick, re-dispatching a worker and piling up duplicate live workers (observed on `njcameron/seogent` PR #12, which looped every ~2 min despite four real owner replies). Both handlers now treat the bot **and** the owner (`config["owner"]`) as factory-side. Review replies stay distinguishable from genuine top-level inline feedback by `in_reply_to_id`, so owner inline review comments are still picked up; owner top-level (issue) comments are treated as factory-side to avoid a self-loop on the worker's own reply. Third-party humans and other review bots (e.g. codex) remain genuine reviewers. (#7)

## v0.7.0 — 2026-06-16

- Stop board-status transitions from silently failing. `Adapters::GithubProjects::IssueTracker#set_status` used to `return` quietly when the issue wasn't in the project-items snapshot, while `StatusTransitions` logged `"plan ready, moving to cc-planning"` (and released the dispatch lock) regardless — so a card that never actually moved was recorded as a success with nothing surfaced. `set_status` now returns whether it applied, and `StatusTransitions` routes a non-applied move (to `cc-planning` or `In review`) through `Context#error` (Slack, throttled) and leaves the lock held, instead of logging a false success. Same class of bug as the v0.2.0 "silent `gh` failure" fixes. (#3)

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
