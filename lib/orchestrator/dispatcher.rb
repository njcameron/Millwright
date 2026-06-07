require "open3"
require "fileutils"

class Orchestrator
  # Dispatches a Claude worker for a Ready / Planning-approved issue:
  # builds the prompt (planning-or-implement vs. implement-approved-plan),
  # fetches issue attachments, locks dispatch, and spawns the worker.
  class Dispatcher
    def initialize(context)
      @ctx = context
    end

    def dispatch(issue)
      number = issue[:number]
      title = issue[:title]
      repo = issue[:repo]
      planning_approved = issue[:status] == @ctx.statuses["planning_approved"]

      unless repo
        @ctx.log "Issue ##{number} has no repository, skipping"
        return
      end

      repo_name = repo.split("/").last
      repo_dir = File.expand_path("../../../#{repo_name}", __dir__)
      log_file = @ctx.worker_runner.daily_log_path("issue-#{number}.log")

      unless Dir.exist?(repo_dir)
        @ctx.log "Issue ##{number}: repo directory not found: #{repo_dir}, skipping"
        return
      end

      mode = planning_approved ? "implement" : "auto"

      if @ctx.dispatch_lock.locked?(number)
        @ctx.log "Issue ##{number}: dispatch lock exists, skipping (already dispatched)"
        return
      end

      if @ctx.dry_run
        @ctx.log "Would dispatch issue ##{number}: #{title} (#{repo}) → #{repo_dir} [mode: #{mode}]"
        return
      end

      @ctx.log "Dispatching issue ##{number}: #{title} (#{repo}) [mode: #{mode}]"
      @ctx.dispatch_lock.lock(number)
      @ctx.update_channel.issue_picked_up(number, title, repo, mode)
      @ctx.issue_tracker.set_status(number, @ctx.statuses["building"], repo: repo)

      branch = branch_name(number, title)
      worktree_dir = File.expand_path("../worktree-#{number}", repo_dir)
      attachments = fetch_attachments(repo, number, repo_dir)
      prompt = build_prompt(number, repo, worktree_dir, branch, attachments,
                            planning_approved: planning_approved)

      pid = @ctx.worker_runner.spawn_worker(prompt: prompt, chdir: repo_dir, log_file: log_file)
      @ctx.log "Spawned claude for issue ##{number} (pid: #{pid})"
    end

    def build_prompt(issue_number, repo, worktree_dir, branch, attachments = "",
                     planning_approved: false)
      task_steps = planning_approved ? approved_task_steps(issue_number, repo) : fresh_task_steps(issue_number, repo)
      plan_primacy_note = planning_approved ? <<~NOTE : ""
        A plan has already been written and approved for issue ##{issue_number}.

        IMPORTANT: The issue comments contain the approved implementation plan and any subsequent
        feedback from the reviewer. These comments are your PRIMARY source of truth — they take
        precedence over the original issue description whenever there is a conflict or the comments
        add detail not in the description. Read ALL comments carefully, especially any posted after
        the plan, as they contain refinements and corrections from the reviewer.

      NOTE

      <<~PROMPT
        You are working on repo #{repo}.
        Issues are tracked in a GitHub Project owned by #{@ctx.config["owner"]}.

        #{plan_primacy_note}IMPORTANT: Post progress comments on the issue as you work, so there is an audit trail.
        Use `#{@ctx.vcs.prompts.post_issue_comment(issue_number: issue_number, repo: repo)}` to post updates.

        NOTIFICATIONS: Send Slack notifications at key moments using:
          #{@ctx.update_channel.prompts.send_message}
        #{attachments}
        Your task:
        #{task_steps.rstrip}
        #{build_and_pr_steps(issue_number, repo, worktree_dir, branch, planning_approved: planning_approved).rstrip}
      PROMPT
    end

    private

    def fresh_task_steps(issue_number, repo)
      vcs = @ctx.vcs.prompts
      it = @ctx.issue_tracker.prompts
      <<~STEPS
        1. Read issue ##{issue_number} using `#{vcs.view_issue(issue_number: issue_number, repo: repo)}`.
        2. Check the issue description. If it says to plan first (e.g. "plan this first", "needs planning", "write a plan"):
           - Write a detailed implementation plan as a comment on the issue:
             `#{vcs.post_issue_comment(issue_number: issue_number, repo: repo, body_placeholder: "<your plan>")}`
           - Add the "needs review" label:
             `#{it.mark_plan_ready(issue_number: issue_number, repo: repo)}`
           - Send a Slack notification: "Plan ready for review: ##{issue_number} <issue title>"
           - STOP. Do not implement anything. The orchestrator will update the project board status.
        3. If NO planning is requested, proceed with implementation as described below.
        4. Post a comment summarising your approach: what you understood from the issue and what you plan to do.
      STEPS
    end

    def approved_task_steps(issue_number, repo)
      vcs = @ctx.vcs.prompts
      it = @ctx.issue_tracker.prompts
      <<~STEPS
        1. Read issue ##{issue_number} using `#{vcs.view_issue(issue_number: issue_number, repo: repo, comments: true)}` to see the approved plan and any reviewer feedback in the comments.
        2. Read ALL comments from top to bottom. The plan comment outlines the approach; any comments
           posted after it contain reviewer feedback that MUST be incorporated into your implementation.
        3. Remove the "needs review" label:
           `#{it.acknowledge_approval(issue_number: issue_number, repo: repo)}`
        4. Post a comment summarising your approach: confirm you've read the approved plan AND any
           reviewer feedback, and outline what you're about to implement (including any adjustments
           based on the feedback).
      STEPS
    end

    def build_and_pr_steps(issue_number, repo, worktree_dir, branch, planning_approved:)
      vcs = @ctx.vcs.prompts
      impl_verb = planning_approved ? "Implement the changes according to the approved plan and reviewer feedback." : "Implement the changes described in the issue."
      <<~STEPS
        5. Fetch latest main and create a git worktree: `#{vcs.create_worktree(worktree_dir: worktree_dir, branch: branch)}`
        6. cd into the worktree: `cd #{worktree_dir}` — ALL subsequent work must happen in this directory.
        7. #{impl_verb}
        8. Before committing, run the linter and fix any issues:
           `bundle exec rubocop -a` — then check for remaining violations with `bundle exec rubocop`.
           Fix any violations that auto-correct didn't handle. Do not commit until rubocop passes clean.
        9. Commit your changes and create a PR:
           `#{vcs.create_pr(issue_number: issue_number, repo: repo, branch: branch, reviewer: @ctx.config["owner"])}`
        10. Post a comment summarising what you implemented and linking the PR.
        11. Send a Slack notification: "PR created: #<pr_number> for issue ##{issue_number}" — include the PR URL.
        12. Clean up the worktree: `#{vcs.remove_worktree(worktree_dir: worktree_dir)}`
      STEPS
    end

    # Content-Type → file extension for extensionless /assets/ image URLs.
    # Only known image types are downloaded; anything else is skipped (see spec).
    IMAGE_EXTENSIONS = {
      "image/png" => "png",
      "image/jpeg" => "jpg",
      "image/gif" => "gif",
      "image/webp" => "webp"
    }.freeze

    # Files attachments carry a real filename/extension; image attachments are
    # bare UUIDs whose extension must be recovered from the Content-Type header.
    # Legacy user-images.githubusercontent.com URLs are out of scope (follow-up).
    ATTACHMENT_URL = %r{https://github\.com/user-attachments/(?:files|assets)/[^\s)]+}

    def fetch_attachments(repo, issue_number, repo_dir)
      body = @ctx.issue_tracker.fetch_issue_body(issue_number, repo: repo)
      return "" if body.nil? || body.empty?

      urls = body.scan(ATTACHMENT_URL)
      return "" if urls.empty?

      attach_dir = File.join(repo_dir, ".issue-attachments", issue_number.to_s)
      FileUtils.mkdir_p(attach_dir)

      filenames = urls.map do |url|
        result = @ctx.vcs.fetch_authenticated(url)
        next if result.nil?
        content, content_type = result
        next if content.nil? || content.empty?

        filename = attachment_filename(url, content_type)
        next if filename.nil?

        File.binwrite(File.join(attach_dir, filename), content)
        filename
      end.compact

      return "" if filenames.empty?

      listing = filenames.map { |f| "  - #{f}" }.join("\n")
      <<~MSG

        ATTACHED FILES from the issue have been downloaded to: .issue-attachments/#{issue_number}/
        Files:
        #{listing}
        These files may include images you can view, not just text to read. Read or view
        them to understand the issue. They may be large — read selectively as needed.
      MSG
    rescue => e
      @ctx.log "Warning: failed to fetch attachments: #{e.message}"
      ""
    end

    # /files/ URLs end in a real filename; keep it. /assets/ URLs are bare
    # UUIDs, so derive <uuid>.<ext> from the Content-Type — skipping (with a
    # warning) anything that isn't a known image type.
    def attachment_filename(url, content_type)
      return url.split("/").last if url.include?("/user-attachments/files/")

      ext = IMAGE_EXTENSIONS[content_type.to_s.split(";").first&.strip]
      if ext.nil?
        @ctx.log "Skipping attachment #{url}: unsupported content type #{content_type.inspect}"
        return nil
      end
      "#{url.split("/").last}.#{ext}"
    end

    def branch_name(number, title)
      slug = title.downcase.gsub(/[^a-z0-9\s-]/, "").strip.gsub(/\s+/, "-")[0..50].chomp("-")
      "#{number}-#{slug}"
    end
  end
end
