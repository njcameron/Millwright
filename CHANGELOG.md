# Changelog

## v0.3.0 — 2026-06-10

- Add a planning feedback loop: a new `PlanCommentHandler` polls the cc-planning column each tick for unaddressed reviewer comments and dispatches a planning-only worker to revise the plan in place (posts the revised plan as a new comment, leaves the card in cc-planning and the "needs review" label untouched). Mirrors `PrCommentHandler` — posts a WIP reply for dedup and locks `plan-<n>` to prevent concurrent revisions. Previously, comments on a plan in cc-planning were never picked up; feedback was only consumed once the card was manually moved to "Planning approved".
- Add `issue_comments` / `post_issue_comment` to the version-control adapter (the GitHub adapter aliases `pr_issue_comments` to `issue_comments`, since PRs are issues in GitHub's API) and a `plan_comments_found` update-channel notification.

## v0.2.0 — 2026-06-09

- Surface operational errors (missing repo checkout, failed `gh` API calls) to Slack via a new throttled `Context#error` path, so failures are visible instead of only logged. Throttling reuses the existing `Cooldown` so a recurring error notifies at most once per backoff window.
- Fix silently-swallowed `gh` comment failures: `post_pr_comment`/`post_review_reply` now capture stderr and raise on non-zero exit (previously `capture2` dropped stderr and ignored exit status, so a 403 looked like success and leaked to the log).

## v0.1.0 — 2026-06-07

- Initial commit.
