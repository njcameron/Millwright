---
name: debug-pr
description: Debug why a PR or issue is stuck by cross-referencing orchestrator logs with GitHub state. Use when asked to check progress on a PR/issue or investigate why work isn't completing.
argument-hint: [pr-or-issue-url-or-number]
---

Debug why a PR or issue is stuck by checking orchestrator logs against GitHub state.

## Input

The user will provide a PR number, issue number, or GitHub URL. Extract the repo and number from it. If only a number is given, check recent orchestrator logs to identify the repo.

## Step 1 — Check GitHub state

Gather current state from GitHub in parallel:

- `gh pr view <number> --repo <owner/repo> --json title,body,state,url` — PR status
- `gh api repos/<owner/repo>/issues/<number>/comments --jq '.[-1]'` — last issue/PR comment
- `gh api repos/<owner/repo>/pulls/<number>/comments --jq '.[-1]'` — last review comment

Note the last comment author, timestamp, and content. This is what the user sees.

## Step 2 — Search orchestrator logs

Search today's orchestrator log for the PR and issue numbers:

```
grep -n "<pr_number>\|<issue_number>" logs/$(date -u +%Y-%m-%d)/orchestrator.log
```

Use `Grep` on `logs/YYYY-MM-DD/orchestrator.log` in the Millwright checkout.

Look for:
- **Dispatch lines**: "dispatching fix" or "unaddressed comment(s)" — did the orchestrator detect work to do?
- **Spawn lines**: "Spawned claude for" — was a worker actually launched?
- **Error lines**: stack traces, `Errno::ENOENT`, permission errors between detection and spawn
- **Status transitions**: "moving to In review", "moving to Done"

If a dispatch was detected but no spawn follows, there is likely a crash between detection and spawn — read the lines immediately after the dispatch line.

## Step 3 — Check worker logs

Worker logs are in `logs/YYYY-MM-DD/` with these naming conventions:
- `pr-<number>.log` — PR review comment workers
- `ci-fix-<number>.log` — CI failure fix workers
- `issue-<number>.log` — issue dispatch workers

Check:
1. **File size** — 0 bytes means the worker either crashed immediately or is still running
2. **File contents** — look for errors, stack traces, or completion messages
3. **Process status** — if the log is empty, check if the process is still alive: `ps aux | grep <pid>`

The PID is logged in the orchestrator spawn line.

## Step 4 — Diagnose

Cross-reference GitHub state with log state. Common failure modes:

| Symptom | Likely cause |
|---|---|
| Dispatch detected, no spawn line, stack trace | Orchestrator crash — bad path, missing binary, permission error |
| Spawn line exists, worker log is 0 bytes, process dead | Worker crashed on startup — bad env, missing dependency |
| Spawn line exists, worker log is 0 bytes, process alive | Worker is still running — just needs time |
| Spawn line exists, worker log has content but no push | Worker hit an error during execution — read the log |
| No dispatch detected at all | Dispatch lock may be active — check `state/` for lock files, or PR has no actionable comments |
| "Working on this" comment but no result | Worker was spawned but failed silently — check worker log and process |

## Step 5 — Report

Tell the user:
1. What the orchestrator did (detected, dispatched, or missed)
2. What the worker did (succeeded, failed, still running)
3. The root cause if something went wrong
4. A fix if applicable
