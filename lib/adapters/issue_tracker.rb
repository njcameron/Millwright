module Adapters
  # Abstract base for issue-tracking adapters (GitHub Projects v2, Linear, Jira, ...).
  #
  # Concrete adapters inherit and implement every method. The orchestrator uses
  # this interface to read board state and to flag issues as ready-for-review.
  # The companion `#prompts` object returns multi-line fragments that workers
  # embed in their prompts (so handlers don't spell provider-specific verbs).
  class IssueTracker
    # Return [{number:, repo:, title:, status:, type:}] for issues currently in `status`.
    def issues_by_status(status)
      raise NotImplementedError
    end

    # Integer: issues currently in any "actively-being-worked-on" state.
    def count_active_workers
      raise NotImplementedError
    end

    # Move `issue_number` (in `repo:`) to `status`. Must be idempotent.
    def set_status(issue_number, status, repo:)
      raise NotImplementedError
    end

    # Return the issue body as a string. Used by the dispatcher to scan for
    # attachment URLs and similar context the worker needs verbatim.
    def fetch_issue_body(issue_number, repo:)
      raise NotImplementedError
    end

    # True if the issue has been flagged as needing human review (e.g. label
    # added, state changed). Generalises GitHub's "needs review" label.
    def flag_for_review?(repo, issue_number)
      raise NotImplementedError
    end

    # Flag the issue as needing review. Idempotent.
    def mark_flagged_for_review(repo, issue_number)
      raise NotImplementedError
    end

    # Returns the Prompts object for this adapter (mark_plan_ready, etc.).
    def prompts
      raise NotImplementedError
    end
  end
end
