require "open3"
require "set"

class Orchestrator
  # Scans "In review" PRs for unaddressed comments and dispatches a Claude
  # worker to reply / make code changes. Posts a "working on this" WIP reply
  # under each comment first so the same comment isn't re-picked-up on the
  # next tick.
  class PrCommentHandler
    IGNORED_AUTHORS = Set["cloudflare-workers-and-pages"].freeze

    def initialize(context)
      @ctx = context
    end

    def call(max_dispatches)
      factory_user = @ctx.config["factory_username"]
      in_review = @ctx.issue_tracker.issues_by_status(@ctx.statuses["pr"])
      dispatched = 0

      if in_review.empty?
        @ctx.log "No PRs in review"
        return
      end

      @ctx.log "Checking #{in_review.size} PR(s) for new comments"

      in_review.each do |issue|
        repo = issue[:repo]
        number = issue[:number]
        next unless repo

        pr = @ctx.vcs.find_pr_for_issue(repo, number)
        unless pr
          @ctx.log "Issue ##{number}: no PR found, skipping"
          next
        end

        pr_number = pr[:number]
        pr_branch = pr[:branch]

        unaddressed = find_unaddressed_comments(repo, pr_number, factory_user)
        next if unaddressed.empty?

        @ctx.log "PR ##{pr_number} (issue ##{number}): #{unaddressed.size} unaddressed comment(s)"

        if @ctx.dry_run
          unaddressed.each { |c| @ctx.log "  - [#{c[:author]}] #{c[:body][0..80]}" }
          next
        end

        next if @ctx.dispatch_lock.locked?("pr-#{pr_number}")
        break if dispatched >= max_dispatches

        post_wip_replies(repo, pr_number, unaddressed)
        @ctx.update_channel.pr_comments_found(number, repo, pr_number, unaddressed.size)
        dispatch_pr_review(issue, repo, pr_number, pr_branch, unaddressed)
        dispatched += 1
      end
    end

    def find_unaddressed_comments(repo, pr_number, factory_user)
      review_comments = @ctx.vcs.pr_review_comments(repo, pr_number)
      issue_comments = @ctx.vcs.pr_issue_comments(repo, pr_number)

      factory_replied_to = review_comments
        .select { |c| c[:author] == factory_user && c[:in_reply_to_id] }
        .map { |c| c[:in_reply_to_id] }
        .to_set

      unaddressed_review = review_comments.select do |c|
        c[:author] != factory_user &&
          !IGNORED_AUTHORS.include?(c[:author]) &&
          c[:in_reply_to_id].nil? &&
          !factory_replied_to.include?(c[:id]) &&
          !c[:body].include?("@claude")
      end

      unaddressed_issue = []
      issue_comments.each_with_index do |c, i|
        next if c[:author] == factory_user
        next if IGNORED_AUTHORS.include?(c[:author])
        next if c[:body].include?("@claude")

        factory_replied_after = issue_comments[(i + 1)..].any? { |later| later[:author] == factory_user }
        unaddressed_issue << c unless factory_replied_after
      end

      unaddressed_review + unaddressed_issue
    end

    private

    def post_wip_replies(repo, pr_number, comments)
      wip = "🔧 Working on this — hang tight."

      review_comments = comments.select { |c| c[:type] == :review }
      issue_comments = comments.select { |c| c[:type] == :issue }

      review_comments.each do |c|
        @ctx.vcs.post_review_reply(repo, pr_number, c[:id], wip)
      end

      return if issue_comments.empty?
      @ctx.vcs.post_pr_comment(repo, pr_number, wip)
    rescue => e
      @ctx.error(
        "PR ##{pr_number}: failed to post WIP reply",
        key: "wip_reply_failed_#{repo}",
        detail: e.message,
        fields: { "Repo" => repo, "PR" => "##{pr_number}" }
      )
    end

    def dispatch_pr_review(issue, repo, pr_number, pr_branch, comments)
      number = issue[:number]
      repo_name = repo.split("/").last
      repo_dir = File.expand_path("../../../#{repo_name}", __dir__)
      log_file = @ctx.worker_runner.daily_log_path("pr-#{pr_number}.log")

      unless Dir.exist?(repo_dir)
        @ctx.error(
          "PR ##{pr_number}: repo checkout not found at #{repo_dir}, skipping",
          key: "repo_missing_#{repo_name}",
          fields: { "Repo" => repo, "PR" => "##{pr_number}" }
        )
        return
      end

      @ctx.dispatch_lock.lock("pr-#{pr_number}")
      @ctx.issue_tracker.set_status(number, @ctx.statuses["building"], repo: repo)

      prompt = build_pr_review_prompt(number, repo, pr_number, pr_branch, comments)
      pid = @ctx.worker_runner.spawn_worker(prompt: prompt, chdir: repo_dir, log_file: log_file)

      @ctx.log "Spawned claude for PR ##{pr_number} review (pid: #{pid})"
    end

    def build_pr_review_prompt(issue_number, repo, pr_number, pr_branch, comments)
      comment_block = comments.map do |c|
        is_bot = c[:author].match?(/\bbot\b|chatgpt|codex|claude|copilot|dependabot/i)
        source = is_bot ? "BOT" : "HUMAN"
        location = c[:path] ? " (#{c[:path]})" : ""
        "[#{source}: #{c[:author]}]#{location}\n#{c[:body]}"
      end.join("\n\n---\n\n")

      vcs = @ctx.vcs.prompts
      <<~PROMPT
        You are working on repo #{repo}.
        You are addressing review comments on PR ##{pr_number} (for issue ##{issue_number}).

        The PR branch is `#{pr_branch}`. Check out this branch and work on it directly:
          `#{vcs.checkout_branch(branch: pr_branch)}`

        Below are the unaddressed comments on this PR. Each is tagged [HUMAN] or [BOT] based on the author.

        IMPORTANT — how to handle comments:

        For HUMAN comments:
        - Address the feedback. Implement the requested change.
        - Reply to the comment explaining what you did.

        For BOT comments:
        - Critically assess whether the suggestion is correct and worthwhile.
        - If you AGREE: implement the fix and reply explaining what you changed.
        - If you DISAGREE: do NOT implement it. Reply explaining why you disagree — be specific
          about why the suggestion is incorrect, unnecessary, or would make things worse.
        - Do not blindly follow bot suggestions. Use your own judgement.

        How to reply to comments:
        - For inline review comments, reply using:
          `#{vcs.reply_to_review_comment(repo: repo, pr_number: pr_number)}`
        - For general PR comments, reply using:
          `#{vcs.post_pr_comment(pr_number: pr_number, repo: repo)}`

        After addressing all comments, run the linter before committing:
          `bundle exec rubocop -a` — then check for remaining violations with `bundle exec rubocop`.
          Fix any violations that auto-correct didn't handle. Do not commit until rubocop passes clean.

        Then commit and push your changes:
          `#{vcs.push_branch(branch: pr_branch)}`

        Then send a Slack notification summarising what you did using:
          #{@ctx.update_channel.prompts.send_message}
        Include how many comments you addressed and whether you agreed or disagreed with any.

        ---

        COMMENTS TO ADDRESS:

        #{comment_block}
      PROMPT
    end
  end
end
