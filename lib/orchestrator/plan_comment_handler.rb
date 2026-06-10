require "set"

class Orchestrator
  # Scans issues parked in the "cc-planning" column for unaddressed reviewer
  # comments and dispatches a Claude worker to revise the plan in place.
  #
  # Mirrors PrCommentHandler, but for plans-under-review rather than
  # PRs-under-review: the issue STAYS in cc-planning (the worker only edits the
  # plan comment, it does not implement anything or change the board status),
  # and a "working on this" reply is posted under the feedback first so the same
  # comment isn't re-picked-up on the next tick.
  class PlanCommentHandler
    IGNORED_AUTHORS = Set["cloudflare-workers-and-pages"].freeze

    def initialize(context)
      @ctx = context
    end

    def call(max_dispatches)
      factory_user = @ctx.config["factory_username"]
      in_planning = @ctx.issue_tracker.issues_by_status(@ctx.statuses["planning"])
      dispatched = 0

      if in_planning.empty?
        @ctx.log "No plans in review"
        return
      end

      @ctx.log "Checking #{in_planning.size} plan(s) for new comments"

      in_planning.each do |issue|
        repo = issue[:repo]
        number = issue[:number]
        next unless repo

        unaddressed = find_unaddressed_comments(repo, number, factory_user)
        next if unaddressed.empty?

        @ctx.log "Issue ##{number}: #{unaddressed.size} unaddressed plan comment(s)"

        if @ctx.dry_run
          unaddressed.each { |c| @ctx.log "  - [#{c[:author]}] #{c[:body][0..80]}" }
          next
        end

        next if @ctx.dispatch_lock.locked?("plan-#{number}")
        break if dispatched >= max_dispatches

        post_wip_reply(repo, number)
        @ctx.update_channel.plan_comments_found(number, repo, unaddressed.size)
        dispatch_plan_revision(issue, repo, number, unaddressed)
        dispatched += 1
      end
    end

    # An issue comment is unaddressed when it's from someone other than the
    # factory bot (and not an ignored bot or an @claude mention) and the factory
    # bot hasn't commented after it. The plan itself is a factory comment, so
    # reviewer feedback posted after the plan reads as unaddressed until the bot
    # replies — both the WIP reply and the revised plan it posts count as a
    # reply, so the feedback won't be re-picked-up once a worker has run.
    def find_unaddressed_comments(repo, issue_number, factory_user)
      comments = @ctx.vcs.issue_comments(repo, issue_number)

      unaddressed = []
      comments.each_with_index do |c, i|
        next if c[:author] == factory_user
        next if IGNORED_AUTHORS.include?(c[:author])
        next if c[:body].include?("@claude")

        factory_replied_after = comments[(i + 1)..].any? { |later| later[:author] == factory_user }
        unaddressed << c unless factory_replied_after
      end
      unaddressed
    end

    private

    def post_wip_reply(repo, issue_number)
      @ctx.vcs.post_issue_comment(repo, issue_number, "🔧 Revising the plan based on your feedback — hang tight.")
    rescue => e
      @ctx.error(
        "Issue ##{issue_number}: failed to post plan WIP reply",
        key: "plan_wip_reply_failed_#{repo}",
        detail: e.message,
        fields: { "Repo" => repo, "Issue" => "##{issue_number}" }
      )
    end

    def dispatch_plan_revision(issue, repo, number, comments)
      repo_name = repo.split("/").last
      repo_dir = File.expand_path("../../../#{repo_name}", __dir__)
      log_file = @ctx.worker_runner.daily_log_path("plan-#{number}.log")

      unless Dir.exist?(repo_dir)
        @ctx.error(
          "Issue ##{number}: repo checkout not found at #{repo_dir}, skipping",
          key: "repo_missing_#{repo_name}",
          fields: { "Repo" => repo, "Issue" => "##{number}" }
        )
        return
      end

      @ctx.dispatch_lock.lock("plan-#{number}")

      prompt = build_plan_revision_prompt(number, repo, comments)
      pid = @ctx.worker_runner.spawn_worker(prompt: prompt, chdir: repo_dir, log_file: log_file)

      @ctx.log "Spawned claude for issue ##{number} plan revision (pid: #{pid})"
    end

    def build_plan_revision_prompt(issue_number, repo, comments)
      comment_block = comments.map { |c| "[#{c[:author]}]\n#{c[:body]}" }.join("\n\n---\n\n")

      vcs = @ctx.vcs.prompts
      <<~PROMPT
        You are working on repo #{repo}.
        You are REVISING the implementation plan for issue ##{issue_number} based on reviewer feedback.

        The issue sits in the "cc-planning" column: a plan has already been posted as a comment
        and is awaiting review. The reviewer has left feedback that you must fold into the plan.

        Your task — this is a PLANNING task, NOT implementation:
        1. Read the issue and ALL of its comments, top to bottom:
           `#{vcs.view_issue(issue_number: issue_number, repo: repo, comments: true)}`
           The earlier comment(s) hold the current plan; the latest comments are the reviewer
           feedback you must address.
        2. Revise the plan to incorporate the feedback. Where the feedback asks a question,
           answer it; where it requests a change, fold that change into the plan.
        3. Post the REVISED PLAN as a new comment, so the latest comment always reflects the
           current plan:
           `#{vcs.post_issue_comment(issue_number: issue_number, repo: repo, body_placeholder: "<your revised plan>")}`
           Open the comment with a short note of what changed in response to the feedback.
        4. Send a Slack notification that the plan has been updated using:
           #{@ctx.update_channel.prompts.send_message}

        IMPORTANT:
        - Do NOT implement anything. Do NOT create a branch, write code, or open a PR.
        - Do NOT change the issue's labels or its project-board status. Leave the "needs review"
          label in place — the human reviewer moves the card to "Planning approved" when ready.
        - The reviewer will read your updated plan and either leave more feedback (which you'll
          revise again) or approve it to start implementation.

        ---

        REVIEWER FEEDBACK TO ADDRESS:

        #{comment_block}
      PROMPT
    end
  end
end
