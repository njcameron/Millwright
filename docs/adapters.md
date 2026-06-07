# Pluggable adapters

Millwright decouples its four external integrations behind adapter interfaces
so the orchestrator stays generic. The default setup ships with GitHub
Projects + GitHub + Slack + Claude Code as the reference implementation.
Swapping any concern is a folder-and-registry change, not a rewrite.

## The four concerns

| Concern | Base class | Default adapter |
|---|---|---|
| Issue tracking (board state) | `Adapters::IssueTracker` | `Adapters::GithubProjects::IssueTracker` |
| Version control (repos, PRs, CI, worker auth) | `Adapters::VersionControl` | `Adapters::Github::VersionControl` |
| Update channel (human-facing notifications) | `Adapters::UpdateChannel` | `Adapters::Slack::UpdateChannel` |
| Coding agent (worker process) | `Adapters::CodingAgent` | `Adapters::ClaudeCode::CodingAgent` |

Each base class lives in `lib/adapters/<concern>.rb` and raises
`NotImplementedError` from every method.

## Selecting adapters

`config.yml`:

```yaml
adapters:
  issue_tracker: github_projects
  version_control: github
  update_channel: slack
  coding_agent: claude_code
```

`Orchestrator::Context.new(config:)` and `RoutineEnv.new(config)` both read
this block and build via `Adapters::Registry`.

## Registry

```ruby
Adapters::Registry.register(:update_channel, :slack, Adapters::Slack::UpdateChannel)
Adapters::Registry.build(:update_channel, :slack, config)
```

Built-in adapters self-register from `lib/adapters/registry.rb`. To add a
new adapter, create `lib/adapters/<provider>/<concern>.rb` inheriting the
base class, then add one `register` line at the bottom of `registry.rb`.

## Prompt fragments

Handlers never inline provider-specific verbs like `gh issue comment …` or
`curl … $webhook`. Those come from `#prompts` accessors on the adapters:

```ruby
@ctx.vcs.prompts.post_issue_comment(issue_number: 42, repo: "u/r")
@ctx.issue_tracker.prompts.mark_plan_ready(issue_number: 42, repo: "u/r")
@ctx.update_channel.prompts.send_message
```

This is why handler prompt bodies are adapter-neutral English — swapping
Slack for Discord or GitHub for GitLab changes the worker's verbs without
touching handler code.

The `CodingAgent` adapter has **no** `#prompts` accessor — coding-agent
differences are about *how to invoke*, not *what to ask*. The prompt body
stays neutral.

## Worker auth flows through VCS

`VersionControl#worker_env` returns the hash that gets merged into the
worker's spawn environment. The GitHub adapter returns
`{ "GH_TOKEN" => …, "GIT_AUTHOR_NAME" => …, … }`. There is no separate
auth interface — the token is consumed by `git push`, `gh`, `glab` etc.,
so it lives with the VCS adapter.

`WorkerRunner#spawn_worker` composes:

```ruby
env = @vcs.worker_env.merge(@coding_agent.env_overrides)
argv = @coding_agent.command(prompt_path: …)
# stdin routing comes from @coding_agent.stdin_mode
```

## Contract tests

`test/adapters/contracts/{issue_tracker,version_control,update_channel,coding_agent}_contract.rb`
are plain Ruby modules. Each concrete adapter test `include`s the matching
contract module and gets uniform coverage of return-value shape and basic
invariants.

To add an adapter, create a test file under `test/adapters/`,
include the contract module, define `build_adapter` (a hermetic instance —
stub the transport), and run `bundle exec rake`. The contract tests will
exercise the new adapter the same way they exercise the GitHub / Slack /
Claude Code defaults.

## Writing a new adapter

Copy the matching skeleton from `docs/adapters/`:

- `EXAMPLE_issue_tracker.rb`
- `EXAMPLE_version_control.rb`
- `EXAMPLE_update_channel.rb`
- `EXAMPLE_coding_agent.rb`

Each `# TODO:` block describes inputs, expected return shape, idempotency
requirements, and any side-effect contracts.

## Known gaps

- **Cross-provider PR↔issue linking.** GitHub finds the linked PR by
  branch-name convention (`NNN-…`). Linear or GitLab adapters would need
  an explicit `issue_link` field plumbed through.
- **Routine-specific verbs.** `lib/routines/security_scan.rb` and
  `weekly_digest.rb` still call `gh pr list --search` / `gh issue view`
  directly rather than going through the adapter. Those calls are
  routine-specific (not part of the general orchestrator loop), so the
  adapter contracts were kept tight rather than expanded to cover them.
  A non-GitHub setup would need to provide its own routine implementations
  for those scripts.
