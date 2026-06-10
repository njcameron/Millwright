require "open3"
require "json"

class Orchestrator
  # Watches "In review" PRs for failed CI runs. When a CI failure is seen,
  # dispatches a Claude worker with the failure logs to attempt a fix.
  # Respects a per-PR retry counter (max_ci_fixes) — once exhausted, fires
  # an exponential-backoff "gave up" Slack notification instead.
  class CiFailureHandler
    DEFAULT_MAX_FIXES = 2

    def initialize(context)
      @ctx = context
    end

    def call(max_dispatches)
      in_review = @ctx.issue_tracker.issues_by_status(@ctx.statuses["pr"])
      return if in_review.empty?

      dispatched = 0

      in_review.each do |issue|
        repo = issue[:repo]
        number = issue[:number]
        next unless repo

        pr = @ctx.vcs.find_pr_for_issue(repo, number)
        next unless pr

        pr_number = pr[:number]
        pr_branch = pr[:branch]

        conclusion = @ctx.vcs.latest_run_conclusion(repo, pr_branch)

        if conclusion == "success"
          reset_ci_fix_count(pr_number)
          next
        end

        next unless conclusion == "failure"

        # Release a lingering lock whose fix worker has already finished, so a
        # subsequent CI failure can be retried (up to max_ci_fixes) without
        # waiting out the lock's full TTL.
        @ctx.dispatch_lock.reap_if_finished("ci-#{pr_number}")
        next if @ctx.dispatch_lock.locked?("ci-#{pr_number}")

        max_ci_fixes = @ctx.config["max_ci_fixes"] || DEFAULT_MAX_FIXES
        count = ci_fix_count(pr_number)
        if count >= max_ci_fixes
          @ctx.cooldown.notify(:"ci_gave_up_#{pr_number}") do
            @ctx.update_channel.ci_fix_gave_up(number, repo, pr_number, count)
          end
          next
        end

        @ctx.log "PR ##{pr_number} (issue ##{number}): CI failed, dispatching fix (attempt #{count + 1}/#{max_ci_fixes})"
        failed_log = @ctx.vcs.fetch_failed_log(repo, pr_branch)
        next if failed_log.nil? || failed_log.strip.empty?

        if @ctx.dry_run
          @ctx.log "Would dispatch CI fix for PR ##{pr_number}"
          next
        end

        break if dispatched >= max_dispatches

        dispatch_ci_fix(issue, repo, pr_number, pr_branch, failed_log)
        increment_ci_fix_count(pr_number)
        dispatched += 1
      end
    end

    private

    def dispatch_ci_fix(issue, repo, pr_number, pr_branch, failed_log)
      number = issue[:number]
      repo_name = repo.split("/").last
      repo_dir = File.expand_path("../../../#{repo_name}", __dir__)
      log_file = @ctx.worker_runner.daily_log_path("ci-fix-#{pr_number}.log")

      unless Dir.exist?(repo_dir)
        @ctx.error(
          "PR ##{pr_number}: repo checkout not found at #{repo_dir}, skipping",
          key: "repo_missing_#{repo_name}",
          fields: { "Repo" => repo, "PR" => "##{pr_number}" }
        )
        return
      end

      @ctx.dispatch_lock.lock("ci-#{pr_number}")
      @ctx.issue_tracker.set_status(number, @ctx.statuses["building"], repo: repo)
      @ctx.update_channel.ci_fix_dispatched(
        number, repo, pr_number, ci_fix_count(pr_number) + 1, @ctx.config["max_ci_fixes"] || DEFAULT_MAX_FIXES
      )

      prompt = build_ci_fix_prompt(number, repo, pr_number, pr_branch, failed_log)
      pid = @ctx.worker_runner.spawn_worker(prompt: prompt, chdir: repo_dir, log_file: log_file)
      @ctx.dispatch_lock.record_pid("ci-#{pr_number}", pid)

      @ctx.log "Spawned claude for CI fix on PR ##{pr_number} (pid: #{pid})"
    end

    def build_ci_fix_prompt(issue_number, repo, pr_number, pr_branch, failed_log)
      vcs = @ctx.vcs.prompts
      <<~PROMPT
        You are working on repo #{repo}.
        You are fixing CI failures on PR ##{pr_number} (for issue ##{issue_number}).

        The PR branch is `#{pr_branch}`. Check out this branch and work on it directly:
          `#{vcs.checkout_branch(branch: pr_branch)}`

        Below are the CI failure logs (truncated to the last 20,000 characters):

        ---
        #{failed_log}
        ---

        Your task:
        1. Read the CI failure logs above carefully.
        2. Identify the root cause of the failure.
        3. Fix the failing tests or code.
        4. Run the test suite locally to verify your fix: `bundle exec rake`
        5. Run the linter before committing:
           `bundle exec rubocop -a` — then check for remaining violations with `bundle exec rubocop`.
           Fix any violations that auto-correct didn't handle. Do not commit until rubocop passes clean.
        6. Commit and push your changes:
           `#{vcs.push_branch(branch: pr_branch)}`
        7. Post a comment on the PR explaining what failed and how you fixed it:
           `#{vcs.post_pr_comment(pr_number: pr_number, repo: repo, body_placeholder: "<your explanation>")}`
        8. Send a Slack notification summarising the fix using:
           #{@ctx.update_channel.prompts.send_message}
      PROMPT
    end

    def ci_fix_count(pr_number)
      path = File.join(@ctx.state_dir, "ci_fix_count_#{pr_number}")
      File.exist?(path) ? File.read(path).to_i : 0
    end

    def increment_ci_fix_count(pr_number)
      path = File.join(@ctx.state_dir, "ci_fix_count_#{pr_number}")
      File.write(path, ci_fix_count(pr_number) + 1)
    end

    def reset_ci_fix_count(pr_number)
      path = File.join(@ctx.state_dir, "ci_fix_count_#{pr_number}")
      File.delete(path) if File.exist?(path)
    end
  end
end
