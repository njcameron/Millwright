module Adapters
  # Abstract base for human-facing update channels (Slack, Discord, email, ...).
  #
  # One method per orchestrator event. Implementations must never raise — a
  # failed notification should not break the orchestrator.
  class UpdateChannel
    def issue_picked_up(issue_number, title, repo, mode)
      raise NotImplementedError
    end

    def plan_ready(issue_number, title, repo)
      raise NotImplementedError
    end

    def pr_created(issue_number, repo, pr_number)
      raise NotImplementedError
    end

    def pr_comments_found(issue_number, repo, pr_number, count)
      raise NotImplementedError
    end

    def pr_comments_addressed(issue_number, repo, pr_number)
      raise NotImplementedError
    end

    def worker_failed(issue_number, repo, error)
      raise NotImplementedError
    end

    def review_queue_full(in_review_count, max_review)
      raise NotImplementedError
    end

    def ci_fix_dispatched(issue_number, repo, pr_number, attempt, max_attempts)
      raise NotImplementedError
    end

    def ci_fix_gave_up(issue_number, repo, pr_number, attempts)
      raise NotImplementedError
    end

    def weekly_digest(content, pr_count)
      raise NotImplementedError
    end

    def security_scan(repo, counts, report = nil, report_path = nil)
      raise NotImplementedError
    end

    def no_slots(active_count, max_workers)
      raise NotImplementedError
    end

    # Returns the Prompts object for this adapter (send_message fragment, ...).
    def prompts
      raise NotImplementedError
    end

    # Env hash merged into the worker's spawn environment so the worker can
    # send notifications (e.g. via $SLACK_WEBHOOK) without the secret being
    # baked into the on-disk prompt. Defaults to none; adapters that need a
    # secret in the worker env override this.
    def worker_env
      {}
    end
  end
end
