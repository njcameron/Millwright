---
name: workers-share-one-checkout
description: Concurrent workers for the same repo share one working tree (.git), so duplicate dispatches clobber each other's edits, HEAD, and push.
metadata:
  type: project
---

All Millwright workers for a given repo run in the SAME checkout: `dispatch_pr_review`/`dispatch_plan_revision` compute `repo_dir = File.expand_path("../../../<repo_name>", __dir__)` and spawn with `chdir: repo_dir`. There is no per-worker worktree.

**Why it matters:** if the orchestrator duplicate-dispatches (the [[wip-reply-failure-dispatch-loop]] bug class — issue #7/#11/#12), two workers edit the SAME files in the SAME working tree simultaneously. Observed on PR #8 (2026-06-17): files mutated under a second worker mid-edit, local HEAD advanced without that worker committing, and both bot review comments ended up with 3 duplicate "Agreed — fixed" replies (one per duplicate worker). Edits silently collide; whoever commits+pushes last wins.

**How to apply:** when you discover you're a worker and another worker is live on the same repo (file mtimes changing under you, unexpected HEAD moves, untracked files you didn't create), do NOT keep editing/committing/pushing — you'll corrupt the shared tree. Check `git log`/`git ls-remote` first: the peer may have already committed+pushed the same fix. Back off interfering edits and verify rather than racing.
